import Foundation
import CryptoKit
import Observation
import ZeusProtocol

/// Per-day AES-GCM storage. Full-text matching is indexed in memory only; no plaintext index is written.
@MainActor @Observable final class EncryptedJournalStore: JournalStore, FrameJournalStoring, TypingJournalStoring {
    private(set) var revision: UInt64 = 0
    private(set) var lastError: String?
    let root: URL
    @ObservationIgnored private let keyProvider: any JournalKeyProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let retentionClock: () -> Date
    @ObservationIgnored private var typingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var nextTypingExpiry: Date?
    @ObservationIgnored private var typingExpiryInitialized = false
    @ObservationIgnored private var index: [String: String] = [:]
    @ObservationIgnored private var forgetEpoch = UUID()
    init(root: URL = ZeusPaths.appSupport.appendingPathComponent("Journal", isDirectory: true),
         keyProvider: any JournalKeyProviding = KeychainJournalKeyProvider(), calendar: Calendar = .current,
         clock: @escaping () -> Date = Date.init) {
        self.root = root; self.keyProvider = keyProvider; self.calendar = calendar; retentionClock = clock
    }
    isolated deinit { typingExpiryTask?.cancel() }
    func append(_ item: JournalItem) throws { try append(item, allowFrame: false) }
    private func append(_ item: JournalItem, allowFrame: Bool) throws {
        try perform {
            guard (item.kind != .frame || allowFrame), !item.id.isEmpty, item.id.utf8.count <= 200,
                  item.time.timeIntervalSince1970.isFinite,
                  item.app.map(Self.isBundleID) ?? true,
                  try JSONEncoder().encode(item).count <= 1_048_576 else { throw LearningStorageError.invalidItem }
            let url = file(item.time)
            var day = try read(url)
            // Idempotent append supports recovery of sent receipts; conflicting IDs are never silently replaced.
            if let existing = try all().first(where: { $0.id == item.id }) {
                guard existing == item else { throw LearningStorageError.invalidItem }; return
            }
            day.append(item)
            try LearningEncryption.write(day, to: url, key: keyProvider)
            index[item.id] = searchable(item); revision &+= 1
            if item.level == .typed, item.kind == .typedText, item.payload.value.text != nil {
                let expiry = Self.wordsExpiry(item)
                if nextTypingExpiry.map({ expiry < $0 }) ?? true { scheduleTypingExpiry(expiry) }
            }
        }
    }
    /// Image ciphertext is written first. Metadata is its commit marker; an interrupted orphan is never visible.
    func appendFrame(_ frame: Redacted<FrameItem>, item: JournalItem) throws {
        try perform {
            let value = frame.value
            guard item.kind == .frame, item.level == .screen, value.width > 0, value.height > 0,
                  value.width <= 1600, value.height <= 1600, !value.heic.isEmpty, value.heic.count <= 4_000_000,
                  value.boxes.count <= 1_000, value.boxes.allSatisfy({ box in
                      [box.x, box.y, box.width, box.height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } &&
                      box.x + box.width <= 1.000001 && box.y + box.height <= 1.000001
                  }) else { throw LearningStorageError.invalidItem }
            let url = frameFile(item.id)
            if let existing = try all().first(where: { $0.id == item.id }) {
                guard existing == item, try self.frame(id: item.id) == frame else { throw LearningStorageError.invalidItem }; return
            }
            try LearningEncryption.write(frame, to: url, key: keyProvider)
            do { try append(item, allowFrame: true) }
            catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }
    func frame(id: String) throws -> Redacted<FrameItem>? {
        try perform {
            guard try all().contains(where: { $0.id == id && $0.kind == .frame }) else { return nil }
            return try LearningEncryption.read(Redacted<FrameItem>.self, at: frameFile(id), key: keyProvider)
        }
    }
    @discardableResult func deleteFrame(id: String, includingDescription: Bool) throws -> FrameDeletionReceipt {
        try perform {
            let rows = try all()
            let before = rows.filter { ($0.id == id && $0.kind == .frame) || ($0.kind == .description && $0.payload.value.details["frame_id"] == id) }
            guard let first = before.first, includingDescription || before.contains(where: { $0.id == id && $0.kind == .frame }) else { throw FrameJournalError.notFound }
            let url = file(first.time)
            guard before.allSatisfy({ file($0.time) == url }) else { throw LearningStorageError.invalidItem }
            let image = try frame(id: id)
            var after: [JournalItem] = []
            if !includingDescription {
                after = before.filter { $0.kind == .description }.map { item in
                    var payload = item.payload.value
                    // Deferred model processing removes private frames through this same atomic path.
                    // Keep its reason rather than describing an automatic removal as a user action.
                    if payload.details["picture_not_kept"] != "private" {
                        payload.details["picture_not_kept"] = "deletedByUser"
                    }
                    return JournalItem(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind,
                                       payload: .init(payload, report: item.payload.report))
                }
                if after.isEmpty {
                    var details = first.payload.value.details; details["frame_id"] = id; details["picture_not_kept"] = "deletedByUser"
                    after = [.init(id: "description_" + id, time: first.time, level: .screen, app: first.app, kind: .description,
                                   payload: .init(.init(description: "Picture deleted by you", details: details)))]
                }
            }
            let ids = Set(before.map(\.id)); let day = try read(url)
            try LearningEncryption.write(day.filter { !ids.contains($0.id) } + after, to: url, key: keyProvider)
            // The atomic day rewrite is the commit marker. A failed unlink leaves only unreachable encrypted bytes,
            // reclaimed by prune/Delete Everything, never a readable picture or a half-deleted description pair.
            try? FileManager.default.removeItem(at: frameFile(id))
            index.removeAll(); revision &+= 1
            return .init(frameID: id, epoch: forgetEpoch, frame: image, before: before, after: after)
        }
    }
    func restoreFrame(_ receipt: FrameDeletionReceipt) throws {
        try perform {
            guard receipt.epoch == forgetEpoch else { throw FrameJournalError.conflict }
            guard let first = receipt.before.first, receipt.before.allSatisfy({ file($0.time) == file(first.time) }) else { throw LearningStorageError.invalidItem }
            let ids = Set((receipt.before + receipt.after).map(\.id)), rows = try all()
            let current = rows.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
            guard current == receipt.after.sorted(by: { $0.id < $1.id }) else { throw FrameJournalError.conflict }
            let url = file(first.time)
            if let image = receipt.frame { try LearningEncryption.write(image, to: frameFile(receipt.frameID), key: keyProvider) }
            do { try LearningEncryption.write(try read(url).filter { !ids.contains($0.id) } + receipt.before, to: url, key: keyProvider) }
            catch { if receipt.frame != nil { try? FileManager.default.removeItem(at: frameFile(receipt.frameID)) }; throw error }
            index.removeAll(); revision &+= 1
        }
    }
    private func frameFile(_ id: String) -> URL {
        // IDs never become path components; no raw title, app name or user-controlled slash reaches disk.
        root.appendingPathComponent(SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".zframe")
    }
    private func removeOrphanFrames() throws {
        let live = Set(try all().filter { $0.kind == .frame }.map { frameFile($0.id).lastPathComponent })
        for url in try frameFiles() where !live.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
    }
    private func frameFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "zframe" }
    }
    func items(matching query: JournalQuery) throws -> [JournalItem] {
        try perform {
            // Enforce expired words before search/export even if the app slept through its timer or capture is off.
            try expireTypingWords(now: retentionClock())
            let needle = query.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return try all().filter { item in
                if let from = query.from, item.time < from { return false }
                if let to = query.to, item.time >= to { return false }
                if !query.levels.isEmpty && !query.levels.contains(item.level) { return false }
                if !query.apps.isEmpty && !query.apps.contains(item.app ?? "") { return false }
                if !query.kinds.isEmpty && !query.kinds.contains(item.kind) { return false }
                return needle.isEmpty || (index[item.id] ?? "").contains(needle)
            }.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
                .prefix(max(0, min(query.limit, 100_000))).map { $0 }
        }
    }
    func delete(_ selection: JournalDeletion) throws {
        try perform {
            if case .item(let id) = selection, try all().contains(where: { $0.id == id && $0.kind == .frame }) {
                _ = try deleteFrame(id: id, includingDescription: false); return
            }
            switch selection {
            case .all, .app, .day: forgetEpoch = UUID()
            case .item: break
            }
            if case .all = selection {
                // Forget works even with an unavailable key or damaged ciphertext.
                for url in try files() + frameFiles() { try FileManager.default.removeItem(at: url); revision &+= 1 }
                index.removeAll(); typingExpiryTask?.cancel(); typingExpiryTask = nil
                nextTypingExpiry = nil; typingExpiryInitialized = true; return
            }
            for url in try files() {
                let old = try read(url)
                let kept = old.filter { item in
                    if item.kind == .sentToAssistant {
                        if case .all = selection { return false }; return true
                    }
                    return switch selection {
                    case .all: false
                    case .item(let id): item.id != id
                    case .app(let app): item.app != app
                    case .day(let day): !calendar.isDate(item.time, inSameDayAs: day)
                    }
                }
                guard kept.count != old.count else { continue }
                if kept.isEmpty { try FileManager.default.removeItem(at: url) }
                else { try LearningEncryption.write(kept, to: url, key: keyProvider) }
                for item in old where !kept.contains(where: { $0.id == item.id }) { index.removeValue(forKey: item.id) }
                revision &+= 1
            }
            try removeOrphanFrames()
        }
    }
    func export(matching query: JournalQuery) throws -> Data {
        try perform {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(items(matching: query))
        }
    }
    func prune(retention: JournalRetention, now: Date) throws { try prune(retention: retention, now: now, onlyScreen: false) }
    /// Words expire at a precise duration, not at a civil-day boundary; topics and their IDs remain unchanged.
    func pruneTyping(words: TypingWordsRetention, now: Date) throws {
        try perform {
            for url in try files() {
                let old = try read(url)
                let kept = old.compactMap { item -> JournalItem? in
                    guard item.level == .typed, item.kind != .sentToAssistant else { return item }
                    guard item.time > now.addingTimeInterval(-30 * 86400) else { return nil }
                    guard item.kind == .typedText, item.payload.value.text != nil else { return item }
                    var value = item.payload.value
                    let expiry = item.time.addingTimeInterval(Double(words.hours) * 3600)
                    value.details["words_expires"] = String(expiry.timeIntervalSince1970)
                    if words == .none || expiry <= now {
                        value.text = nil; value.details["words_not_kept"] = words == .none ? "setting" : (words == .week ? "expired7Days" : "expired24Hours")
                    }
                    return .init(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind,
                                 payload: .init(value, report: item.payload.report))
                }
                guard kept != old else { continue }
                if kept.isEmpty { try FileManager.default.removeItem(at: url) }
                else { try LearningEncryption.write(kept, to: url, key: keyProvider) }
                index.removeAll(); revision &+= 1
            }
            typingExpiryInitialized = false; try expireTypingWords(now: now)
        }
    }
    private static func wordsExpiry(_ item: JournalItem) -> Date {
        let declared = item.payload.value.details["words_expires"].flatMap(Double.init)
        let fallback = item.time.addingTimeInterval(86400)
        guard let declared, declared.isFinite else { return fallback }
        return min(Date(timeIntervalSince1970: declared), item.time.addingTimeInterval(7 * 86400))
    }
    private func expireTypingWords(now: Date) throws {
        guard !typingExpiryInitialized || nextTypingExpiry.map({ $0 <= now }) == true else { return }
        var next: Date?
        for url in try files() {
            let old = try read(url)
            let kept = old.map { item -> JournalItem in
                guard item.level == .typed, item.kind == .typedText, item.payload.value.text != nil else { return item }
                let expiry = Self.wordsExpiry(item)
                if expiry > now { next = min(next ?? expiry, expiry); return item }
                var value = item.payload.value; value.text = nil
                value.details["words_not_kept"] = expiry.timeIntervalSince(item.time) > 86400 ? "expired7Days" : "expired24Hours"
                return .init(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind,
                             payload: .init(value, report: item.payload.report))
            }
            if kept != old {
                try LearningEncryption.write(kept, to: url, key: keyProvider); index.removeAll(); revision &+= 1
            }
        }
        typingExpiryInitialized = true; scheduleTypingExpiry(next)
    }
    private func scheduleTypingExpiry(_ date: Date?) {
        typingExpiryTask?.cancel(); nextTypingExpiry = date
        guard let date else { typingExpiryTask = nil; return }
        let delay = max(0, date.timeIntervalSince(retentionClock()))
        typingExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            typingExpiryInitialized = false
            do { try expireTypingWords(now: retentionClock()) }
            catch { lastError = "Zeus couldn't remove expired typing words." }
        }
    }
    func pruneScreens(descriptionDays: Int, now: Date) throws {
        var retention = JournalRetention(); retention.frameDays = 7
        retention.descriptionDays = [7, 30, 90].contains(descriptionDays) ? descriptionDays : 90
        try prune(retention: retention, now: now, onlyScreen: true)
    }
    private func prune(retention: JournalRetention, now: Date, onlyScreen: Bool) throws {
        try perform {
            for url in try files() {
                let old = try read(url)
                var kept = old.filter { item in
                    if item.kind == .sentToAssistant || (onlyScreen && item.level != .screen) { return true }
                    let days: Int
                    switch item.level {
                    case .activity: days = retention.activityDays
                    case .focus: days = retention.focusDays
                    case .screen: days = item.kind == .frame ? retention.frameDays : retention.descriptionDays
                    case .typed: days = retention.typedDays
                    }
                    let cutoff = calendar.date(byAdding: .day, value: -max(0, days), to: calendar.startOfDay(for: now)) ?? now
                    return item.time >= cutoff
                }
                kept = kept.map { item in
                    guard !onlyScreen, item.level == .typed, item.kind == .typedText, item.payload.value.text != nil else { return item }
                    let expiry = Self.wordsExpiry(item)
                    guard expiry <= now else { return item }
                    var value = item.payload.value; value.text = nil
                    value.details["words_not_kept"] = expiry.timeIntervalSince(item.time) > 86400 ? "expired7Days" : "expired24Hours"
                    return .init(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind,
                                 payload: .init(value, report: item.payload.report))
                }
                let expired = Set(old.filter { $0.kind == .frame && !kept.contains($0) }.map(\.id))
                kept = kept.map { item in
                    guard item.kind == .description, let id = item.payload.value.details["frame_id"], expired.contains(id) else { return item }
                    var payload = item.payload.value; payload.details["picture_not_kept"] = "expired"
                    return JournalItem(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind,
                                       payload: .init(payload, report: item.payload.report))
                }
                guard kept != old else { continue }
                if kept.isEmpty { try FileManager.default.removeItem(at: url) }
                else { try LearningEncryption.write(kept, to: url, key: keyProvider) }
                index.removeAll(); revision &+= 1
            }
            try removeOrphanFrames()
        }
    }
    private func file(_ date: Date) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return root.appendingPathComponent(String(format: "%04d-%02d-%02d.zjournal", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zjournal" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func read(_ url: URL) throws -> [JournalItem] {
        try LearningEncryption.read([JournalItem].self, at: url, key: keyProvider) ?? []
    }
    private func all() throws -> [JournalItem] {
        let items = try files().flatMap { try read($0) }
        for item in items { index[item.id] = searchable(item) }
        return items
    }
    private func searchable(_ item: JournalItem) -> String {
        (item.payload.value.description + "\n" + (item.payload.value.topic ?? "") + "\n" + (item.payload.value.text ?? ""))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    private func perform<T>(_ body: () throws -> T) throws -> T {
        do { let result = try body(); lastError = nil; return result }
        catch { lastError = "Zeus couldn't read or save its local journal."; throw error }
    }
    static func isBundleID(_ string: String) -> Bool {
        !string.isEmpty && string.utf8.count <= 255 && string.contains(".") &&
        string.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }
    }
}
