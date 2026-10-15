import Foundation
import CryptoKit
import Observation
import ZeusProtocol

/// Per-day AES-GCM storage. Full-text matching is indexed in memory only; no plaintext index is written.
@MainActor @Observable final class EncryptedJournalStore: JournalStore, FrameJournalStoring {
    private(set) var revision: UInt64 = 0
    private(set) var lastError: String?
    let root: URL
    @ObservationIgnored private let keyProvider: any JournalKeyProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var index: [String: String] = [:]
    init(root: URL = ZeusPaths.appSupport.appendingPathComponent("Journal", isDirectory: true),
         keyProvider: any JournalKeyProviding = KeychainJournalKeyProvider(), calendar: Calendar = .current) {
        self.root = root; self.keyProvider = keyProvider; self.calendar = calendar
    }
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
            if case .all = selection {
                // Forget works even with an unavailable key or damaged ciphertext.
                for url in try files() + frameFiles() { try FileManager.default.removeItem(at: url); revision &+= 1 }
                index.removeAll(); return
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
    func pruneScreens(descriptionDays: Int, now: Date) throws {
        var retention = JournalRetention(); retention.frameDays = 7
        retention.descriptionDays = [7, 30, 90].contains(descriptionDays) ? descriptionDays : 90
        try prune(retention: retention, now: now, onlyScreen: true)
    }
    private func prune(retention: JournalRetention, now: Date, onlyScreen: Bool) throws {
        try perform {
            for url in try files() {
                let old = try read(url)
                let kept = old.filter { item in
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
                guard kept.count != old.count else { continue }
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
        (item.payload.value.description + "\n" + (item.payload.value.text ?? ""))
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
