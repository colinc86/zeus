import Foundation
import CryptoKit

/// One raw level-1 event (CONTRACT §13): which app is frontmost, launches and quits, lock/sleep, idle periods and
/// display count. Never keystrokes, clipboard, window titles, URLs, file names, screenshots, audio or location.
struct ActivityEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case activate, launch, quit, lock, unlock, sleep, wake
        /// No input for 5 minutes or more; `t` is the last input.
        case idle
        /// Input again after an idle period; `t` is the first input.
        case active
        /// Time in an excluded app: `seconds` only, never a bundle id or name.
        case `private`
        case displays
    }
    var t: Date
    var kind: Kind
    /// Bundle id, for app events.
    var app: String?
    var name: String?
    var seconds: Double?
    var displays: Int?

    init(t: Date, kind: Kind, app: String? = nil, name: String? = nil, seconds: Double? = nil, displays: Int? = nil) {
        self.t = t; self.kind = kind; self.app = app; self.name = name; self.seconds = seconds; self.displays = displays
    }

    /// The user is at the Mac at `t`.
    var showsPresence: Bool { [.activate, .active, .unlock, .wake, .private].contains(kind) }
    /// The user left at `t`.
    var startsAbsence: Bool { [.idle, .lock, .sleep].contains(kind) }
    var appName: String { name ?? app ?? "an app" }

    /// "Switched to Xcode", as Settings › Privacy lists today's events.
    var plainDescription: String {
        switch kind {
        case .activate: "Switched to \(appName)"
        case .launch: "Opened \(appName)"
        case .quit: "Quit \(appName)"
        case .lock: "Locked the screen"
        case .unlock: "Unlocked the screen"
        case .sleep: "Mac went to sleep"
        case .wake: "Mac woke up"
        case .idle: "Away: no input for 5 min or more"
        case .active: "Back"
        case .private: "A private app for \(LearningSummarizer.duration(seconds ?? 0))"
        case .displays: (displays ?? 1) == 1 ? "1 display" : "\(displays ?? 1) displays"
        }
    }
}

/// Raw events on this Mac: one JSON-lines file per day in `Application Support/Zeus/Activity/`, readable only by the
/// user (0600, folder 0700). Not synced anywhere. Tests pass their own `root`.
@MainActor
final class ActivityStore {
    let root: URL
    let calendar: Calendar
    private let journal: (any JournalStore)?
    private static let filePermissions = 0o600
    private static let folderPermissions = 0o700

    init(root: URL, calendar: Calendar = .current, journal: (any JournalStore)? = nil) {
        self.journal = journal
        self.root = root
        self.calendar = calendar
    }

    /// `2026-10-13`, in the store's calendar.
    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func fileURL(for day: Date) -> URL { root.appendingPathComponent(dayKey(day) + ".jsonl") }

    func append(_ event: ActivityEvent) throws {
        guard journal == nil else { throw LearningStorageError.invalidItem }
        try ensureFolder()
        let url = fileURL(for: event.t)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                 attributes: [.posixPermissions: Self.filePermissions]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.encoder.encode(event) + Data("\n".utf8))
    }

    /// The day's events in time order. Lines that don't parse are skipped.
    func events(on day: Date) -> [ActivityEvent] {
        if journal != nil { return journalItems(on: day).compactMap(Self.activityEvent) }
        guard let text = try? String(contentsOf: fileURL(for: day), encoding: .utf8) else { return [] }
        let events = text.split(separator: "\n").compactMap { try? Self.decoder.decode(ActivityEvent.self, from: Data($0.utf8)) }
        return events.enumerated().sorted { $0.element.t == $1.element.t ? $0.offset < $1.offset : $0.element.t < $1.element.t }.map(\.element)
    }

    /// Days with a raw file, oldest first, as the start of each day.
    func recordedDays() -> [Date] {
        if let journal {
            var query = JournalQuery(); query.levels = [.activity]; query.kinds = [.activity]; query.limit = 100_000
            return Array(Set(((try? journal.items(matching: query)) ?? []).map { calendar.startOfDay(for: $0.time) })).sorted()
        }
        return rawFiles().compactMap(\.day).sorted()
    }

    /// Deletes raw files older than `keepingDays` days. Learnings are pruned by `LearningsStore`.
    func prune(now: Date, keepingDays: Int) {
        if let journal {
            var query = JournalQuery(); query.levels = [.activity]; query.kinds = [.activity]; query.limit = 100_000
            query.to = calendar.date(byAdding: .day, value: -keepingDays, to: calendar.startOfDay(for: now))
            for item in (try? journal.items(matching: query)) ?? [] { try? journal.delete(.item(item.id)) }
        }
        guard let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: calendar.startOfDay(for: now)) else { return }
        for file in rawFiles() where file.day.map({ $0 < cutoff }) ?? false {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Removes every file in the Activity folder.
    func deleteEverything() {
        if let journal {
            var query = JournalQuery(); query.levels = [.activity]; query.kinds = [.activity]; query.limit = 100_000
            for item in (try? journal.items(matching: query)) ?? [] { try? journal.delete(.item(item.id)) }
        }
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes a private file (0600) in the folder, replacing it atomically.
    func writePrivate(_ data: Data, named name: String) throws {
        try ensureFolder()
        let url = root.appendingPathComponent(name)
        let temp = root.appendingPathComponent("." + name + ".tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: Self.filePermissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
    func read(named name: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(name)) }

    private func ensureFolder() throws {
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: Self.folderPermissions])
    }

    private func rawFiles() -> [(url: URL, day: Date?)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.map { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return (url, nil) }
            return (url, calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])))
        }
    }


    /// Only LearnFromMe's post-redaction pipeline uses this write path.
    func appendRedacted(_ payload: Redacted<JournalPayload>, event: ActivityEvent, id: String = UUID().uuidString) throws {
        guard let journal else { throw LearningStorageError.invalidItem }
        try journal.append(.init(id: id, time: event.t, level: .activity, app: event.app, kind: .activity, payload: payload))
    }
    func journalItems(on day: Date) -> [JournalItem] {
        guard let journal else { return [] }
        var query = JournalQuery(); query.levels = [.activity]; query.kinds = [.activity]; query.limit = 100_000
        query.from = calendar.startOfDay(for: day); query.to = calendar.date(byAdding: .day, value: 1, to: query.from ?? day)
        return (try? journal.items(matching: query)) ?? []
    }
    static func payload(_ event: ActivityEvent) -> JournalPayload {
        var details = ["kind": event.kind.rawValue]
        if let name = event.name { details["name"] = name }
        if let seconds = event.seconds { details["seconds"] = String(seconds) }
        if let displays = event.displays { details["displays"] = String(displays) }
        return .init(description: event.plainDescription, details: details)
    }
    static func activityEvent(_ item: JournalItem) -> ActivityEvent? {
        let details = item.payload.value.details
        guard let kind = details["kind"].flatMap(ActivityEvent.Kind.init(rawValue:)) else { return nil }
        return .init(t: item.time, kind: kind, app: item.app, name: details["name"],
                     seconds: details["seconds"].flatMap(Double.init), displays: details["displays"].flatMap(Int.init))
    }
    /// Source files remain until every permitted event has committed. Stable IDs make interrupted migration idempotent.
    func migrateLegacy(redactor: any Redactor, allowed: (ActivityEvent) -> Bool, stillAllowed: () -> Bool) async throws {
        guard journal != nil else { return }
        for file in rawFiles() {
            guard stillAllowed() else { return }
            let data = try Data(contentsOf: file.url)
            for (offset, line) in data.split(separator: 10).enumerated() {
                guard let event = try? Self.decoder.decode(ActivityEvent.self, from: Data(line)), allowed(event) else { continue }
                let payload = await redactor.redact(Self.payload(event))
                guard stillAllowed(), allowed(event) else { return }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try appendRedacted(payload, event: event, id: "l1_\(hash)_\(offset)")
            }
            guard stillAllowed() else { return }
            try FileManager.default.removeItem(at: file.url)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
