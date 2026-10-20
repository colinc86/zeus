import Foundation
import CryptoKit
import Observation
import ZeusProtocol

/// Per-day AES-GCM storage. Full-text matching is indexed in memory only; no plaintext index is written.
@MainActor @Observable final class EncryptedJournalStore: JournalSnapshotProviding, FrameJournalStoring, TypingJournalStoring, LearningStorageRecovering, JournalDeletionObserving, JournalFolderSource, JournalAppendHistory {
    @ObservationIgnored var onFolderDeletion: ((Set<String>?) -> Void)?
    @ObservationIgnored var onJournalDeletion: ((Set<String>?) -> Void)?
    private(set) var revision: UInt64 = 0 {
        didSet {
            snapshotCache = nil; snapshotKey = nil; snapshotStamp = nil
            if let appended = pendingAppend, appendLog.count < 4_096 { appendLog.append((revision, appended)) }
            else { appendLog.removeAll(); appendLogFloor = revision }
            pendingAppend = nil
        }
    }
    private(set) var lastError: String?
    private(set) var storageWaitingForUnlock = false
    var pendingStorageWrites: Int { pendingEntries.count }
    @ObservationIgnored private var pendingEntries: [(JournalItem, Redacted<FrameItem>?)] = []
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    let root: URL
    @ObservationIgnored private let keyProvider: any JournalKeyProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let retentionClock: () -> Date
    @ObservationIgnored private var typingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var nextTypingExpiry: Date?
    @ObservationIgnored private var typingExpiryInitialized = false
    @ObservationIgnored private var typingForgetEpoch = UUID()
    @ObservationIgnored private var typingWordsPreference: TypingWordsRetention?
    @ObservationIgnored private var typingTopicsPreference = 30
    /// Search text, filled lazily by text queries only. In memory only, like `partitionCache`.
    @ObservationIgnored private var index: [String: String] = [:]
    /// Decrypted day partitions, valid only for the file identity they were read from and for the current key.
    /// Never written to disk. Every read still asks the key provider once per operation, so a locked keychain fails closed.
    @ObservationIgnored private var partitionCache: [String: CachedPartition] = [:]
    @ObservationIgnored private var partitionCacheKey: Data?
    /// Bumped whenever this store writes or removes a partition; part of the folder writer's per-day token.
    @ObservationIgnored private var partitionWrites: [String: UInt64] = [:]
    @ObservationIgnored private var partitionWriteCount: UInt64 = 0
    /// Items appended since `appendLogFloor` (the last revision that rewrote or removed anything).
    @ObservationIgnored private var appendLog: [(revision: UInt64, item: JournalItem)] = []
    @ObservationIgnored private var appendLogFloor: UInt64 = 0
    @ObservationIgnored private var pendingAppend: JournalItem?
    @ObservationIgnored private let scopedKey: OperationScopedJournalKey
    /// Number of partitions decrypted and decoded; used by the performance regression tests.
    @ObservationIgnored private(set) var partitionDecodeCount = 0
    private struct FileStamp: Equatable { let inode: UInt64; let size: Int64; let modified: Int; let modifiedNanos: Int; let changed: Int; let changedNanos: Int }
    private struct CachedPartition { let stamp: FileStamp; let items: [JournalItem]; let ids: Set<String> }
    @ObservationIgnored private var forgetEpoch = UUID()
    @ObservationIgnored var snapshotRead: @Sendable ([URL], Data) async throws -> [JournalSnapshotPartition] = { urls, secret in
        try await JournalSnapshotReader.read(urls, secret: secret)
    }
    @ObservationIgnored private var snapshotCache: JournalSnapshot?
    @ObservationIgnored private var snapshotKey: Data?
    @ObservationIgnored private var snapshotStamp: SnapshotStamp?
    private struct SnapshotStamp: Equatable {
        let revision: UInt64
        let forget: UUID
        let typing: UUID
        let words: TypingWordsRetention?
        let topics: Int
    }
    private var currentSnapshotStamp: SnapshotStamp {
        .init(revision: revision, forget: forgetEpoch, typing: typingForgetEpoch, words: typingWordsPreference, topics: typingTopicsPreference)
    }
    init(root: URL = ZeusPaths.appSupport.appendingPathComponent("Journal", isDirectory: true),
         keyProvider: any JournalKeyProviding = KeychainJournalKeyProvider(), calendar: Calendar = .current,
         clock: @escaping () -> Date = Date.init) {
        self.root = root; self.keyProvider = keyProvider; self.calendar = calendar; retentionClock = clock
        scopedKey = OperationScopedJournalKey(keyProvider)
    }
    isolated deinit { typingExpiryTask?.cancel(); recoveryTask?.cancel() }
    func append(_ item: JournalItem) throws {
        // Freeze the original retention deadline before queuing; later preferences may only shorten it.
        let prepared = try applyingTypingRetention(to: item)
        do { try append(prepared, allowFrame: false) }
        catch where LearningStorageAvailability.isUnavailable(error) { try queue(prepared, frame: nil) }
    }
    private func queue(_ item: JournalItem, frame: Redacted<FrameItem>?) throws {
        if let existing = pendingEntries.first(where: { $0.0.id == item.id }) {
            guard existing.0 == item, existing.1 == frame else { throw LearningStorageError.invalidItem }
            lastError = LearningStorageAvailability.waitingMessage; return
        }
        guard pendingEntries.count < 100,
              pendingEntries.reduce(0, { $0 + ($1.1?.value.heic.count ?? 0) }) + (frame?.value.heic.count ?? 0) <= 24_000_000 else { throw LearningStorageError.keyUnavailable }
        pendingEntries.append((item, frame)); storageWaitingForUnlock = true
        lastError = LearningStorageAvailability.waitingMessage; scheduleRecovery()
    }
    private func scheduleRecovery() {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }; self.recoveryTask = nil; self.retryPendingWrites()
        }
    }
    private func refreshPendingRetention() throws {
        pendingEntries = try pendingEntries.compactMap { entry in
            do { return (try applyingTypingRetention(to: entry.0), entry.1) }
            catch TypingJournalError.expired { return nil }
        }
    }
    func retryPendingWrites() {
        do { try refreshPendingRetention() }
        catch { lastError = "Zeus couldn't apply retention to queued learning entries."; return }
        while let entry = pendingEntries.first {
            do {
                if let frame = entry.1 { try persistFrame(frame, item: entry.0) }
                else { try append(entry.0, allowFrame: false) }
                pendingEntries.removeFirst()
            } catch {
                storageWaitingForUnlock = LearningStorageAvailability.isUnavailable(error)
                lastError = storageWaitingForUnlock ? LearningStorageAvailability.waitingMessage : "Zeus couldn't save a queued learning entry."
                if storageWaitingForUnlock { scheduleRecovery() }; return
            }
        }
        storageWaitingForUnlock = false; lastError = nil
    }
    private func append(_ item: JournalItem, allowFrame: Bool) throws {
        try perform {
            let item = try applyingTypingRetention(to: item)
            guard (item.kind != .frame || allowFrame), !item.id.isEmpty, item.id.utf8.count <= 200,
                  item.time.timeIntervalSince1970.isFinite,
                  item.app.map(Self.isBundleID) ?? true,
                  try JSONEncoder().encode(item).count <= 1_048_576 else { throw LearningStorageError.invalidItem }
            let url = file(item.time)
            var day = try read(url)
            // Idempotent append supports recovery of sent receipts; conflicting IDs are never silently replaced.
            if let existing = try existingItem(id: item.id) {
                guard existing == item else { throw LearningStorageError.invalidItem }; return
            }
            day.append(item)
            try writePartition(day, to: url)
            if !index.isEmpty { index[item.id] = searchable(item) }
            pendingAppend = item; revision &+= 1
            if item.level == .typed, item.kind == .typedText {
                let expiry = item.payload.value.text == nil ? Self.topicExpiry(item) : min(Self.wordsExpiry(item), Self.topicExpiry(item))
                if nextTypingExpiry.map({ expiry < $0 }) ?? true { scheduleTypingExpiry(expiry) }
            }
        }
    }
    /// Image ciphertext is written first. Metadata is its commit marker; an interrupted orphan is never visible.
    func appendFrame(_ frame: Redacted<FrameItem>, item: JournalItem) throws {
        do { try persistFrame(frame, item: item) }
        catch where LearningStorageAvailability.isUnavailable(error) { try queue(item, frame: frame) }
    }
    private func persistFrame(_ frame: Redacted<FrameItem>, item: JournalItem) throws {
        try perform {
            let value = frame.value
            guard item.kind == .frame, item.level == .screen, value.width > 0, value.height > 0,
                  value.width <= 1600, value.height <= 1600, !value.heic.isEmpty, value.heic.count <= 4_000_000,
                  value.boxes.count <= 1_000, value.boxes.allSatisfy({ box in
                      [box.x, box.y, box.width, box.height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } &&
                      box.x + box.width <= 1.000001 && box.y + box.height <= 1.000001
                  }) else { throw LearningStorageError.invalidItem }
            let url = frameFile(item.id)
            if let existing = try existingItem(id: item.id) {
                guard existing == item, try self.frame(id: item.id) == frame else { throw LearningStorageError.invalidItem }; return
            }
            try LearningEncryption.write(frame, to: url, key: keyProvider)
            do { try append(item, allowFrame: true) }
            catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }
    func frame(id: String) throws -> Redacted<FrameItem>? {
        try perform {
            guard try existingItem(id: id)?.kind == .frame else { return nil }
            return try LearningEncryption.read(Redacted<FrameItem>.self, at: frameFile(id), key: scopedKey)
        }
    }
    @discardableResult func deleteFrame(id: String, includingDescription: Bool) throws -> FrameDeletionReceipt {
        try perform {
            let rows = try all()
            let before = rows.filter { ($0.id == id && $0.kind == .frame) || ($0.kind == .description && $0.payload.value.details["frame_id"] == id) }
            guard let first = before.first, includingDescription || before.contains(where: { $0.id == id && $0.kind == .frame }) else { throw FrameJournalError.notFound }
            let locations = try partitions(for: Set(before.map(\.id)))
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
            let ids = Set(before.map(\.id))
            try replace(ids: ids, with: after, partitions: locations)
            // The atomic metadata transaction is the commit marker. A failed unlink leaves only unreachable encrypted bytes,
            // reclaimed by prune/Delete Everything, never a readable picture or a half-deleted description pair.
            try? FileManager.default.removeItem(at: frameFile(id))
            index.removeAll(); revision &+= 1
            reportDeletion(ids.subtracting(Set(after.map(\.id))))
            return .init(frameID: id, epoch: forgetEpoch, frame: image, before: before, after: after, partitions: locations)
        }
    }
    func restoreFrame(_ receipt: FrameDeletionReceipt) throws {
        try perform {
            guard receipt.epoch == forgetEpoch else { throw FrameJournalError.conflict }
            guard !receipt.before.isEmpty else { throw LearningStorageError.invalidItem }
            let ids = Set((receipt.before + receipt.after).map(\.id)), rows = try all()
            let current = rows.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
            guard current == receipt.after.sorted(by: { $0.id < $1.id }) else { throw FrameJournalError.conflict }
            if let image = receipt.frame { try LearningEncryption.write(image, to: frameFile(receipt.frameID), key: keyProvider) }
            do { try replace(ids: ids, with: receipt.before, partitions: receipt.partitions) }
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
    /// Transaction recovery and key access precede detached reads. No stale or unscrubbed result is published.
    func journalSnapshot() async throws -> JournalSnapshot {
        while true {
            try Task.checkCancellation()
            do {
                let urls = try files()
                let secret = try keyProvider.key()
                guard secret.count == 32 else { throw LearningStorageError.keyUnavailable }
                let stamp = currentSnapshotStamp
                if let snapshotCache, snapshotStamp == stamp, snapshotKey == secret,
                   snapshotCache.expiresAt.map({ $0 > retentionClock() }) ?? true {
                    return snapshotCache
                }
                snapshotCache = nil; snapshotKey = nil; snapshotStamp = nil
                let partitions: [JournalSnapshotPartition]
                do { partitions = try await snapshotRead(urls, secret) }
                catch {
                    try Task.checkCancellation()
                    if stamp != currentSnapshotStamp { continue }
                    throw error
                }
                try Task.checkCancellation()
                guard stamp == currentSnapshotStamp else { continue }
                // A recovered transaction or an unavailable/replaced key must never be bypassed by captured bytes.
                guard try files() == urls else { continue }
                guard try keyProvider.key() == secret else { throw LearningStorageError.keyUnavailable }
                guard stamp == currentSnapshotStamp else { continue }
                let now = retentionClock()
                var next: Date?
                var retained: [JournalItem] = []
                for partition in partitions {
                    let kept = try partition.items.compactMap { item -> JournalItem? in
                        guard item.level == .typed, item.kind == .typedText else { return item }
                        let topicExpiry = effectiveTopicExpiry(item)
                        guard topicExpiry > now else { return nil }
                        next = min(next ?? topicExpiry, topicExpiry)
                        let value = try applyingTypingRetention(to: item)
                        if value.payload.value.text != nil {
                            let expiry = Self.wordsExpiry(value); next = min(next ?? expiry, expiry)
                        }
                        return value
                    }
                    if kept != partition.items {
                        // Keep the physical partition and the existing expiry commit semantics. A partial failure
                        // retains successful revision increments but publishes nothing; a retry reads committed files.
                        try writePartition(kept, to: partition.url)
                        index.removeAll(); revision &+= 1
                    }
                    retained += kept
                }
                guard next.map({ $0 > retentionClock() }) ?? true else { continue }
                typingExpiryInitialized = true; scheduleTypingExpiry(next)
                let value = JournalSnapshot(revision: revision, items: retained, expiresAt: next)
                snapshotCache = value; snapshotKey = secret; snapshotStamp = currentSnapshotStamp
                lastError = pendingEntries.isEmpty ? nil : LearningStorageAvailability.waitingMessage
                return value
            } catch is CancellationError { throw CancellationError() }
            catch {
                snapshotCache = nil; snapshotKey = nil; snapshotStamp = nil
                lastError = "Zeus couldn't read or save its local journal."
                throw error
            }
        }
    }

    func items(matching query: JournalQuery) throws -> [JournalItem] {
        try perform {
            // Enforce expired words before search/export even if the app slept through its timer or capture is off.
            try expireTypingWords(now: retentionClock())
            let needle = query.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            var matches: [JournalItem] = []
            for url in try files() {
                for item in try read(url) {
                    if let from = query.from, item.time < from { continue }
                    if let to = query.to, item.time >= to { continue }
                    if !query.levels.isEmpty && !query.levels.contains(item.level) { continue }
                    if !query.apps.isEmpty && !query.apps.contains(item.app ?? "") { continue }
                    if !query.kinds.isEmpty && !query.kinds.contains(item.kind) { continue }
                    if !needle.isEmpty {
                        let text = index[item.id] ?? searchable(item)
                        index[item.id] = text
                        guard text.contains(needle) else { continue }
                    }
                    matches.append(item)
                }
            }
            return matches.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
                .prefix(max(0, min(query.limit, 100_000))).map { $0 }
        }
    }
    func delete(_ selection: JournalDeletion) throws {
        // Forget is authoritative over queued data even when protected files cannot yet be read.
        var removed = Set<String>()
        defer { if !removed.isEmpty { reportDeletion(removed) } }
        pendingEntries.removeAll { entry in
            let item = entry.0
            let matches: Bool = switch selection {
            case .all: true
            case .item(let id): item.kind != .sentToAssistant && item.id == id
            case .app(let app): item.kind != .sentToAssistant && item.app == app
            case .day(let day): item.kind != .sentToAssistant && calendar.isDate(item.time, inSameDayAs: day)
            }
            if matches { removed.insert(item.id) }
            return matches
        }
        if pendingEntries.isEmpty { recoveryTask?.cancel(); recoveryTask = nil; storageWaitingForUnlock = false }
        try perform {
            if case .item(let id) = selection, try all().contains(where: { $0.id == id && $0.kind == .frame }) {
                _ = try deleteFrame(id: id, includingDescription: false); return
            }
            switch selection {
            case .all, .app, .day: forgetEpoch = UUID(); typingForgetEpoch = UUID()
            case .item: break
            }
            if case .all = selection {
                // Forget works even with an unavailable key or damaged ciphertext.
                if FileManager.default.fileExists(atPath: transactionFile.path) { try FileManager.default.removeItem(at: transactionFile) }
                for url in try physicalFiles() + frameFiles() { try removePartition(url); revision &+= 1 }
                index.removeAll(); typingExpiryTask?.cancel(); typingExpiryTask = nil
                nextTypingExpiry = nil; typingExpiryInitialized = true
                reportDeletion(nil); return
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
                if kept.isEmpty { try removePartition(url) }
                else { try writePartition(kept, to: url) }
                for item in old where !kept.contains(where: { $0.id == item.id }) { index.removeValue(forKey: item.id); removed.insert(item.id) }
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
        try pruneTyping(words: words, topicsDays: 30, now: now)
    }
    func pruneTyping(words: TypingWordsRetention, topicsDays: Int, now: Date) throws {
        try perform {
            let days = [7, 30, 90].contains(topicsDays) ? topicsDays : 30
            if words.hours < (typingWordsPreference ?? .day).hours || days < typingTopicsPreference { typingForgetEpoch = UUID() }
            typingWordsPreference = words; typingTopicsPreference = days
            try refreshPendingRetention()
            typingExpiryInitialized = false
            for url in try files() {
                let old = try read(url)
                let kept = old.compactMap { item -> JournalItem? in
                    guard item.level == .typed, item.kind != .sentToAssistant else { return item }
                    guard item.time > now.addingTimeInterval(-Double(days) * 86400) else { return nil }
                    guard item.kind == .typedText else { return item }
                    var value = item.payload.value
                    value.details["topic_expires"] = String(item.time.addingTimeInterval(Double(days) * 86400).timeIntervalSince1970)
                    // A longer preference affects new runs; it never extends the original word deadline.
                    let expiry = min(Self.wordsExpiry(item), item.time.addingTimeInterval(Double(words.hours) * 3600))
                    if value.text != nil { value.details["words_expires"] = String(expiry.timeIntervalSince1970) }
                    if value.text != nil && (words == .none || expiry <= now) {
                        value.text = nil; value.details["words_not_kept"] = words == .none ? "setting" : (expiry.timeIntervalSince(item.time) > 86400 ? "expired7Days" : "expired24Hours")
                    }
                    return .init(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind,
                                 payload: .init(value, report: item.payload.report))
                }
                guard kept != old else { continue }
                if kept.isEmpty { try removePartition(url) }
                else { try writePartition(kept, to: url) }
                index.removeAll(); revision &+= 1
            }
            typingExpiryInitialized = false; try expireTypingWords(now: now)
        }
    }
    func deleteTyping(ids: Set<String>) throws -> TypingDeletionReceipt {
        try perform {
            try expireTypingWords(now: retentionClock())
            let selected = try all().filter { ids.contains($0.id) && $0.level == .typed && $0.kind == .typedText }
            guard !ids.isEmpty, selected.count == ids.count else { throw TypingJournalError.notFound }
            let locations = try partitions(for: ids)
            try replace(ids: ids, with: [], partitions: locations)
            index.removeAll(); revision &+= 1
            reportDeletion(ids)
            return .init(epoch: typingForgetEpoch, items: selected, partitions: locations)
        }
    }
    func restoreTyping(_ receipt: TypingDeletionReceipt) throws {
        try perform {
            guard receipt.epoch == typingForgetEpoch, !receipt.items.isEmpty else { throw TypingJournalError.conflict }
            let ids = Set(receipt.items.map(\.id)), now = retentionClock()
            guard ids.count == receipt.items.count, receipt.items.allSatisfy({ $0.level == .typed && $0.kind == .typedText }),
                  try !all().contains(where: { ids.contains($0.id) }) else { throw TypingJournalError.conflict }
            guard receipt.items.allSatisfy({ Self.topicExpiry($0) > now }) else { throw TypingJournalError.expired }
            let restored = try receipt.items.map { try applyingTypingRetention(to: $0) }
            try replace(ids: ids, with: restored, partitions: receipt.partitions)
            index.removeAll(); revision &+= 1; typingExpiryInitialized = false
        }
    }
    /// Also covers single-run Undo through append: a stale UI token cannot restore disallowed/expired words.
    private func applyingTypingRetention(to item: JournalItem) throws -> JournalItem {
        guard item.level == .typed, item.kind == .typedText else { return item }
        let now = retentionClock()
        guard effectiveTopicExpiry(item) > now else { throw TypingJournalError.expired }
        var value = item.payload.value
        if typingWordsPreference != nil { value.details["topic_expires"] = String(effectiveTopicExpiry(item).timeIntervalSince1970) }
        if let choice = typingWordsPreference, value.text != nil {
            let expiry = min(Self.wordsExpiry(item), item.time.addingTimeInterval(Double(choice.hours) * 3600))
            value.details["words_expires"] = String(expiry.timeIntervalSince1970)
            if choice == .none { value.text = nil; value.details["words_not_kept"] = "setting" }
        }
        let updated = JournalItem(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind,
                                  payload: .init(value, report: item.payload.report))
        return value.text != nil && Self.wordsExpiry(updated) <= now ? Self.withoutExpiredWords(updated) : updated
    }
    private func effectiveTopicExpiry(_ item: JournalItem) -> Date {
        guard typingWordsPreference != nil else { return Self.topicExpiry(item) }
        return min(Self.topicExpiry(item), item.time.addingTimeInterval(Double(typingTopicsPreference) * 86400))
    }
    private static func topicExpiry(_ item: JournalItem) -> Date {
        let declared = item.payload.value.details["topic_expires"].flatMap(Double.init)
        guard let declared, declared.isFinite else { return item.time.addingTimeInterval(30 * 86400) }
        return min(Date(timeIntervalSince1970: declared), item.time.addingTimeInterval(90 * 86400))
    }
    private static func withoutExpiredWords(_ item: JournalItem) -> JournalItem {
        var value = item.payload.value; value.text = nil
        value.details["words_not_kept"] = wordsExpiry(item).timeIntervalSince(item.time) > 86400 ? "expired7Days" : "expired24Hours"
        return .init(id: item.id, time: item.time, level: item.level, app: item.app, kind: item.kind, payload: .init(value, report: item.payload.report))
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
            let kept = try old.compactMap { item -> JournalItem? in
                guard item.level == .typed, item.kind == .typedText else { return item }
                let topicExpiry = effectiveTopicExpiry(item)
                guard topicExpiry > now else { return nil }
                next = min(next ?? topicExpiry, topicExpiry)
                let retained = try applyingTypingRetention(to: item)
                if retained.payload.value.text != nil {
                    let expiry = Self.wordsExpiry(retained); next = min(next ?? expiry, expiry)
                }
                return retained
            }
            if kept != old {
                try writePartition(kept, to: url); index.removeAll(); revision &+= 1
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
                if kept.isEmpty { try removePartition(url) }
                else { try writePartition(kept, to: url) }
                index.removeAll(); revision &+= 1
            }
            try removeOrphanFrames()
        }
    }
    private var transactionFile: URL { root.appendingPathComponent("pending.ztransaction") }
    private func partitionURL(_ name: String) throws -> URL {
        guard name.range(of: #"^\d{4}-\d{2}-\d{2}\.zjournal$"#, options: .regularExpression) != nil else {
            throw LearningStorageError.corrupt
        }
        return root.appendingPathComponent(name)
    }
    /// Replay a committed multi-file replacement before any reader or subsequent mutation can see partial state.
    private func finishTransaction() throws {
        guard let changes = try LearningEncryption.read([String: [JournalItem]].self, at: transactionFile, key: scopedKey) else { return }
        let targets = try changes.sorted { $0.key < $1.key }.map { (try partitionURL($0.key), $0.value) }
        for (url, rows) in targets { try writePartition(rows, to: url) }
        index.removeAll()
        try FileManager.default.removeItem(at: transactionFile)
    }
    private func partitions(for ids: Set<String>) throws -> [String: String] {
        var result: [String: String] = [:]
        for url in try files() {
            for item in try read(url) where ids.contains(item.id) { result[item.id] = url.lastPathComponent }
        }
        return result
    }
    /// The encrypted transaction file is the atomic commit point. It contains no plaintext staging data.
    private func replace(ids: Set<String>, with replacements: [JournalItem], partitions locations: [String: String]) throws {
        var changes: [String: [JournalItem]] = [:]
        for url in try files() {
            let rows = try read(url), kept = rows.filter { !ids.contains($0.id) }
            if kept != rows { changes[url.lastPathComponent] = kept }
        }
        for item in replacements {
            let name = locations[item.id] ?? file(item.time).lastPathComponent
            let url = try partitionURL(name)
            if changes[name] == nil { changes[name] = try read(url) }
            changes[name, default: []].append(item)
        }
        guard !changes.isEmpty else { return }
        if changes.count == 1, let (name, rows) = changes.first {
            try writePartition(rows, to: partitionURL(name))
        } else {
            try LearningEncryption.write(changes, to: transactionFile, key: keyProvider)
            // The transaction is committed even if checkpointing is interrupted. Reads fail closed until replay succeeds.
            try? finishTransaction()
        }
    }
    private func file(_ date: Date) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return root.appendingPathComponent(String(format: "%04d-%02d-%02d.zjournal", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }
    private func reportDeletion(_ ids: Set<String>?) {
        onFolderDeletion?(ids)
        onJournalDeletion?(ids)
    }
    func folderDays() throws -> [Date] {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar; format.timeZone = calendar.timeZone; format.dateFormat = "yyyy-MM-dd"
        return try files().compactMap { format.date(from: $0.deletingPathExtension().lastPathComponent) }
    }
    func folderItems(on day: Date) throws -> [JournalItem] {
        try withOperationKey {
            try expireTypingWords(now: retentionClock())
            return try read(file(day))
        }
    }
    /// Changes whenever the day's partition does, whoever wrote it: the file identity plus this store's own write count.
    func folderDayToken(on day: Date) -> String? {
        let url = file(day), writes = partitionWrites[url.lastPathComponent] ?? 0
        guard let stamp = Self.stamp(url) else { return "none:\(writes)" }
        return "\(stamp.inode):\(stamp.size):\(stamp.modified).\(stamp.modifiedNanos):\(stamp.changed).\(stamp.changedNanos):\(writes)"
    }
    /// The items appended since `revision`, oldest first, or nil when anything was rewritten or removed since then.
    func appendedItems(since revision: UInt64) -> [JournalItem]? {
        guard revision <= self.revision, revision >= appendLogFloor else { return nil }
        return appendLog.filter { $0.revision > revision }.map(\.item)
    }
    private func files() throws -> [URL] {
        try finishTransaction()
        return try physicalFiles()
    }
    private func physicalFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zjournal" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func read(_ url: URL) throws -> [JournalItem] {
        try finishTransaction()
        let name = url.lastPathComponent
        guard let stamp = Self.stamp(url) else { partitionCache.removeValue(forKey: name); return [] }
        let secret = try scopedKey.key()
        if partitionCacheKey != secret { partitionCache.removeAll(); partitionCacheKey = secret }
        if let cached = partitionCache[name], cached.stamp == stamp { return cached.items }
        let bytes = try Data(contentsOf: url)
        let items = try LearningEncryption.decode([JournalItem].self, bytes: bytes, url: url, secret: secret)
        partitionDecodeCount += 1
        // Cache only if the file did not change while it was read.
        if Self.stamp(url) == stamp { partitionCache[name] = .init(stamp: stamp, items: items, ids: Set(items.map(\.id))) }
        return items
    }
    private func all() throws -> [JournalItem] {
        try files().flatMap { try read($0) }
    }
    private func existingItem(id: String) throws -> JournalItem? {
        for url in try files() {
            let items = try read(url)
            if let cached = partitionCache[url.lastPathComponent], !cached.ids.contains(id) { continue }
            if let item = items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }
    /// Every partition write goes through here so the decrypted cache never serves replaced contents.
    private func writePartition(_ rows: [JournalItem], to url: URL) throws {
        let name = url.lastPathComponent
        partitionCache.removeValue(forKey: name)
        partitionWriteCount &+= 1; partitionWrites[name] = partitionWriteCount
        // Writes ask the provider themselves (one call, as before), so losing the key mid-transaction still interrupts it.
        let secret = try keyProvider.key()
        try LearningEncryption.write(rows, to: url, key: FetchedJournalKey(secret, protected: keyProvider.requiresProtectedFiles))
        if partitionCacheKey != secret { partitionCache.removeAll(); partitionCacheKey = secret }
        if let stamp = Self.stamp(url) { partitionCache[name] = .init(stamp: stamp, items: rows, ids: Set(rows.map(\.id))) }
    }
    private func removePartition(_ url: URL) throws {
        let name = url.lastPathComponent
        partitionCache.removeValue(forKey: name)
        partitionWriteCount &+= 1; partitionWrites[name] = partitionWriteCount
        try FileManager.default.removeItem(at: url)
    }
    private static func stamp(_ url: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return .init(inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                     changed: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
    /// One keychain read per operation for its reads instead of one per partition; writes still ask each time.
    private func withOperationKey<T>(_ body: () throws -> T) rethrows -> T {
        scopedKey.begin(); defer { scopedKey.end() }
        return try body()
    }
    private func searchable(_ item: JournalItem) -> String {
        (item.payload.value.description + "\n" + (item.payload.value.topic ?? "") + "\n" + (item.payload.value.text ?? ""))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    private func perform<T>(_ body: () throws -> T) throws -> T {
        do { let result = try withOperationKey(body); lastError = pendingEntries.isEmpty ? nil : LearningStorageAvailability.waitingMessage; return result }
        catch { lastError = "Zeus couldn't read or save its local journal."; throw error }
    }
    static func isBundleID(_ string: String) -> Bool {
        JournalAppName.isBundleID(string)
    }
}

@MainActor private final class FetchedJournalKey: JournalKeyProviding {
    private let secret: Data
    let requiresProtectedFiles: Bool
    init(_ secret: Data, protected: Bool) { self.secret = secret; requiresProtectedFiles = protected }
    func key() throws -> Data { secret }
}
/// Memoizes the key for the duration of one store operation (begin/end may nest). Outside an operation every
/// call reaches the provider, so lock and key-replacement checks keep their existing behavior.
@MainActor private final class OperationScopedJournalKey: JournalKeyProviding {
    private let provider: any JournalKeyProviding
    private var depth = 0
    private var cached: Data?
    init(_ provider: any JournalKeyProviding) { self.provider = provider }
    var requiresProtectedFiles: Bool { provider.requiresProtectedFiles }
    func begin() { depth += 1 }
    func end() { depth -= 1; if depth == 0 { cached = nil } }
    func key() throws -> Data {
        if depth > 0, let cached { return cached }
        let value = try provider.key()
        if depth > 0 { cached = value }
        return value
    }
}
