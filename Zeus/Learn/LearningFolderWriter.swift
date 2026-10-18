import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers

/// One-way readable export. Inputs are retained journal records and redacted summaries,
/// never capture sources. All destinations and the private manifest are injected.
@MainActor @Observable final class LearningFolderWriter: LearningFolderRecording, LearningFolderErasing {
    private(set) var folderURL: URL?
    private(set) var lastWriteError: String?
    private var exportRevision: UInt64 = 0
    @ObservationIgnored var enabledLevels: () -> Set<JournalLevel>
    @ObservationIgnored private let journal: any JournalStore
    @ObservationIgnored private let rules: (any RulesStore)?
    @ObservationIgnored private let redactor: any Redactor
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var disk: LearningFolderDisk?
    @ObservationIgnored private var ownFolder: URL?
    @ObservationIgnored private var managedFolder: URL?
    @ObservationIgnored private var learnings: (any LearningsProviding)?
    @ObservationIgnored private var safeLearnings: [String: Learning] = [:]
    @ObservationIgnored private var safeRules: [String: (String, String)] = [:]
    @ObservationIgnored private var messageRatings: [MessageRating]?
    @ObservationIgnored private var reflections: [String: LearningFolderReflection] = [:]
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var workID = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var itemPaths: [String: String] = [:]

    init(journal: any JournalStore, rules: (any RulesStore)?, stateURL: URL,
         enabledLevels: @escaping () -> Set<JournalLevel>, redactor: any Redactor = LocalRedactor(), calendar: Calendar = .current) {
        self.journal = journal; self.rules = rules; self.enabledLevels = enabledLevels
        self.redactor = redactor; self.calendar = calendar
        do { let disk = try LearningFolderDisk(stateURL: stateURL); self.disk = disk; ownFolder = disk.ownFolder; folderURL = ownFolder }
        catch { lastWriteError = "Zeus couldn't read its folder record. Your existing files were left alone." }
    }
    isolated deinit { work?.cancel(); disk?.invalidate() }
    func setFolder(_ folder: URL?) {
        guard let disk else { return }
        let normalized = folder?.standardizedFileURL.resolvingSymlinksInPath()
        do { try disk.setOwnFolder(normalized); ownFolder = normalized; updateFolder() }
        catch { lastWriteError = "Zeus couldn't save the learnings folder choice." }
    }
    func setManagedFolder(_ folder: URL?) {
        let normalized = folder?.standardizedFileURL.resolvingSymlinksInPath()
        guard managedFolder != normalized else { return }; managedFolder = normalized; updateFolder()
    }
    private func updateFolder() {
        let selected = managedFolder ?? ownFolder
        guard folderURL != selected else { refresh(); return }
        work?.cancel(); disk?.invalidate(); generation = UUID()
        folderURL = selected; itemPaths.removeAll(); observe(); refresh()
    }
    func start(learnings: any LearningsProviding) {
        self.learnings = learnings
        guard !running else { refresh(); return }; running = true; generation = UUID()
        (journal as? any JournalFolderSource)?.onFolderDeletion = { [weak self] ids in
            guard let self else { return }
            self.work?.cancel(); self.disk?.invalidate()
            if ids == nil { self.safeLearnings.removeAll(); self.reflections.removeAll() }
            if let root = self.folderURL {
                do { try self.disk?.erase(root: root, ids: ids) }
                catch { self.lastWriteError = "Zeus couldn't remove files from its learnings folder." }
            }
            self.refresh()
        }
        observe(); refresh()
    }
    func stop() {
        running = false; generation = UUID(); work?.cancel(); work = nil; disk?.invalidate()
        (journal as? any JournalFolderSource)?.onFolderDeletion = nil
    }
    func deleteFolderContents(includeAssistantNotes: Bool) throws {
        work?.cancel(); disk?.invalidate(); safeLearnings.removeAll(); reflections.removeAll()
        guard let root = folderURL, let disk else { return }
        do { try disk.erase(root: root, ids: nil, includeNotes: includeAssistantNotes); itemPaths.removeAll(); lastWriteError = nil; exportRevision &+= 1 }
        catch { lastWriteError = "Zeus couldn't empty its learnings folder."; throw error }
    }
    func dayFolderURL(for date: Date) -> URL? {
        _ = exportRevision
        guard let root = folderURL else { return nil }
        return disk?.existingDirectory(root, path: "Zeus/days/" + day(date))
    }
    func fileURL(forJournalItem item: JournalItem) -> URL? {
        _ = exportRevision
        guard let root = folderURL, enabledLevels().contains(item.level) else { return nil }
        return disk?.existing(root, path: itemPaths[item.id] ?? path(for: item))
    }
    private func observe() {
        guard running else { return }; let token = generation
        withObservationTracking {
            _ = journal.revision; _ = rules?.revision; _ = enabledLevels()
            _ = (learnings as? any LearningHistoryProviding)?.allLearnings
            _ = learnings?.unreadLearnings()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.refresh(); self.observe()
            }
        }
    }
    /// Rebuild in bounded day/file batches. Changing folders or erasing invalidates every old batch.
    func refresh() {
        work?.cancel(); workID = UUID()
        guard running, let root = folderURL, let disk else { return }
        let token = disk.invalidate(), generation = generation
        work = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let source = self.journal as? any JournalFolderSource
                let days: [Date?] = try (source?.folderDays() ?? []).map { Optional($0) } + [nil]
                var kept = Set<String>()
                for day in days {
                    let (files, streamed) = try await self.files(on: day, root: root, disk: disk, token: token)
                    try Task.checkCancellation()
                    guard self.running, self.generation == generation, self.folderURL == root else { return }
                    kept.formUnion(streamed); kept.formUnion(files.map(\.path))
                    for start in stride(from: 0, to: files.count, by: 20) {
                        let batch = Array(files[start..<min(files.count, start + 20)])
                        try await Task.detached(priority: .utility) { try disk.apply(batch, root: root, token: token) }.value
                        try Task.checkCancellation()
                    }
                    await Task.yield()
                }
                let keep = kept
                try await Task.detached(priority: .utility) { try disk.prune(root: root, keeping: keep, token: token) }.value
                self.lastWriteError = Self.collisionMessage(disk.collisionPaths); self.exportRevision &+= 1
            } catch is CancellationError { }
            catch LearningFolderError.stale { }
            catch { self.lastWriteError = "Zeus couldn't update its learnings folder. The retained journal is unchanged." }
        }
    }
    static func collisionMessage(_ paths: [String]) -> String? {
        guard let first = paths.sorted().first else { return nil }
        if paths.count == 1 { return "Zeus didn't replace \(first) because it isn't a file Zeus wrote. Move or rename it to let Zeus write there." }
        let others = paths.count - 1
        return "Zeus didn't replace \(first) and \(others) other \(others == 1 ? "file" : "files") because Zeus didn't write them. Move or rename them to let Zeus write there."
    }
    /// Also used by isolated tests; waits for the latest bounded snapshot, not an arbitrary delay.
    func flush() async {
        refresh()
        while !Task.isCancelled {
            let id = workID, task = work
            await task?.value
            if id == workID { return }
        }
    }
    func recordLearning(_ learning: Learning) async -> [String] {
        safeLearnings[learning.id] = learning
        await flush()
        let path = learningPath(learning)
        guard lastWriteError == nil, let root = folderURL, enabledLevels().contains(.activity), disk?.existing(root, path: path) != nil else { return [] }
        return [path]
    }
    func setReflections(_ records: [LearningFolderReflection]) {
        let next = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        guard Set(next.keys) != Set(reflections.keys) || next.contains(where: { reflections[$0.key]?.text.value != $0.value.text.value }) else { return }
        reflections = next; refresh()
    }
    func recordReflection(id: String, text: Redacted<String>, at: Date) async -> [String] {
        reflections[id] = .init(id: id, text: text, time: at)
        await flush()
        let path = "Zeus/reflections/" + day(at) + ".md"
        guard lastWriteError == nil, let root = folderURL, !enabledLevels().isEmpty, disk?.existing(root, path: path) != nil else { return [] }
        return [path]
    }
    private func formatted(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = pattern
        return f.string(from: date)
    }
    private func day(_ date: Date) -> String { formatted(date, "yyyy-MM-dd") }
    private func learningPath(_ learning: Learning) -> String {
        "Zeus/days/" + day(learning.createdAt) + (learning.kind == .digest ? "/summary.md" : "/moments.md")
    }
    private func path(for item: JournalItem) -> String {
        let base = "Zeus/days/" + day(item.time) + "/"
        if item.kind == .frame || item.kind == .description {
            let frameID = item.payload.value.details["frame_id"] ?? item.id
            let app = String((item.app ?? "app").map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" }.prefix(48))
            let suffix = LearningFolderDisk.hash(Data(frameID.utf8)).prefix(8)
            return base + "screen/" + formatted(item.time, "HHmmss") + "-" + app + "-" + suffix + (item.kind == .frame ? ".jpg" : ".md")
        }
        switch item.kind {
        case .reflection: return "Zeus/reflections/" + day(item.time) + ".md"
        case .sentToAssistant: return base + "sent.md"
        case .outcome: return base + "outcomes.md"
        default: return base + (item.level == .activity ? "activity.md" : item.level == .focus ? "focus.md" : "typing.md")
        }
    }
    private func files(on day: Date?, root: URL, disk: LearningFolderDisk, token: UInt64) async throws -> ([LearningFolderFile], Set<String>) {
        let levels = enabledLevels()
        let items: [JournalItem]
        if let source = journal as? any JournalFolderSource {
            items = try day.map { try source.folderItems(on: $0).filter { levels.contains($0.level) } } ?? []
        } else {
            var query = JournalQuery(); query.limit = 100_000
            items = try journal.items(matching: query).filter { levels.contains($0.level) }
        }
        var streamed = Set<String>()
        var texts: [String: String] = [:], ids: [String: Set<String>] = [:], result: [LearningFolderFile] = []
        var paths: [String: String] = [:]
        func append(_ path: String, id: String, text: String) throws {
            texts[path, default: ""] += text + "\n\n"; ids[path, default: []].insert(id)
            if texts[path, default: ""].utf8.count > 16_000_000 { throw LearningFolderError.tooLarge }
        }
        for item in items.sorted(by: { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }) {
            try Task.checkCancellation()
            let path = path(for: item); paths[item.id] = path
            if item.kind == .frame {
                if try disk.reuseFrame(root: root, path: path, id: item.id, token: token) {
                    streamed.insert(path); continue
                }
                if let store = journal as? any FrameJournalStoring, let image = try store.frame(id: item.id) {
                    let jpeg = try await Task.detached(priority: .utility) { try Self.jpeg(image.value.heic) }.value
                    try Task.checkCancellation()
                    guard levels == enabledLevels() else { throw CancellationError() }
                    let file = LearningFolderFile(path: path, data: jpeg, ids: [item.id])
                    try await Task.detached(priority: .utility) { try disk.apply([file], root: root, token: token) }.value
                    streamed.insert(path)
                }
            } else {
                let payload = item.payload.value
                let details = payload.details.keys.sorted().map { $0 + ": " + (payload.details[$0] ?? "") }.joined(separator: "\n")
                let text = (["## " + formatted(item.time, "HH:mm:ss"), payload.description, payload.topic, payload.text, details].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "\n\n")
                try append(path, id: item.id, text: text)
            }
        }
        if day == nil {
        if let messageRatings { try append("Zeus/preferences.md", id: "preferences", text: MessageRatingStore.preferences(messageRatings)) }
        let history = (learnings as? any LearningHistoryProviding)?.allLearnings ?? learnings?.unreadLearnings() ?? []
        let retained = Set(history.map(\.id))
        if learnings is any LearningHistoryProviding { safeLearnings = safeLearnings.filter { retained.contains($0.key) } }
        if levels.contains(.activity) {
            for learning in history where safeLearnings[learning.id] == nil {
                // Learnings are generated from safe inputs; preserve the same facts the assistant receives.
                safeLearnings[learning.id] = learning
            }
            for learning in safeLearnings.values.sorted(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }) {
                try append(learningPath(learning), id: learning.id, text: learning.text)
            }
        }
        if !levels.isEmpty {
            for record in reflections.values.sorted(by: { $0.time < $1.time }) {
                try append("Zeus/reflections/" + self.day(record.time) + ".md", id: record.id, text: record.text.value)
            }
            var rows: [String] = []
            for rule in rules?.rules ?? [] {
                let hash = LearningFolderDisk.hash(Data(rule.sentence.utf8))
                let sentence: String
                if let cached = safeRules[rule.id], cached.0 == hash { sentence = cached.1 }
                else {
                    sentence = await redactor.redact(rule.sentence).value; try Task.checkCancellation()
                    safeRules[rule.id] = (hash, sentence)
                }
                let confidence = rule.confidence >= 0.75 ? "Sure" : rule.confidence >= 0.45 ? "Fairly sure" : "Unsure"
                rows.append("- " + sentence + " — " + rule.status.rawValue + "; " + confidence + "; " + (rule.author ?? rule.updatedBy).rawValue)
            }
            try append("Zeus/rules.md", id: "rules", text: "# Rules\n\n" + rows.joined(separator: "\n"))
        }
        }
        if day == nil, !levels.isEmpty {
            try append("Zeus/README.md", id: "readme", text: Self.readme)
        }
        result += texts.map { .init(path: $0.key, data: Data($0.value.utf8), ids: ids[$0.key] ?? []) }
        itemPaths.merge(paths) { _, new in new }
        return (result.sorted { $0.path < $1.path }, streamed)
    }
    nonisolated static func jpeg(_ bytes: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LearningFolderError.invalidPicture }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw LearningFolderError.invalidPicture }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw LearningFolderError.invalidPicture }; return data as Data
    }
    private static let readme = """
    # What Zeus keeps

    This is your assistant's record of what Zeus learns, after your levels and privacy safeguards.
    Zeus writes here; edits to its files are overwritten. Files you delete in Finder are not re-created.
    Zeus only replaces or deletes files it wrote itself; anything else in this folder is left alone.
    Retention and deletion in Zeus apply to these files too. The assistant owns Notes/ beside Zeus/.

    - days/YYYY-MM-DD/activity.md: activity timeline, with private apps unnamed
    - days/YYYY-MM-DD/focus.md: redacted window titles and URLs
    - days/YYYY-MM-DD/screen/: retained safeguarded JPG pictures and Markdown descriptions
    - days/YYYY-MM-DD/typing.md: topics and redacted words only while retained
    - days/YYYY-MM-DD/summary.md and moments.md: digests and notes, sent or waiting
    - days/YYYY-MM-DD/outcomes.md and sent.md: outcomes and exact sent ledger content
    - reflections/YYYY-MM-DD.md: reflection text as delivered
    - rules.md: current rules, status, confidence and author
    - preferences.md: message kinds rated Up, Need-to-know or Stop, with redacted examples

    Zeus never sends your data anywhere itself. Your assistant reads its folder; where that goes depends on the assistant you chose.
    """
}

extension LearningFolderWriter: RatingFolderRecording {
    func clearRatingPreferences() { messageRatings = nil; refresh() }
    func recordRatings(_ ratings: [MessageRating]) async -> [String] {
        messageRatings = ratings
        await flush()
        guard lastWriteError == nil, let root = folderURL, disk?.existing(root, path: "Zeus/preferences.md") != nil else { return [] }
        return ["Zeus/preferences.md"]
    }
}
