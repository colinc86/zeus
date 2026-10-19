import Foundation
import Synchronization
import Testing
@testable import Zeus

@MainActor struct JournalSnapshotTests {
    @Test func tenThousandItemsScanOncePerRevisionAndNeverDecryptOnMain() async throws {
        let f = try SnapshotFixture(); defer { f.remove() }
        let metrics = SnapshotReads()
        var days: [String: [JournalItem]] = [:]
        for index in 0..<10_000 {
            let date = f.now.addingTimeInterval(-Double(index % 28) * 86400 + Double(index / 28))
            let item = JournalItem(id: "item-\(index)", time: date, level: .focus, app: "test.editor", kind: .focus,
                payload: .init(.init(description: "Editor", text: "Window: Project Orchid\nDocument: Orchid.swift — /synthetic")))
            days[f.day(date), default: []].append(item)
        }
        for (name, items) in days { try LearningEncryption.write(items, to: f.root.appendingPathComponent(name), key: f.key) }
        f.store.snapshotRead = { urls, secret in
            try await JournalSnapshotReader.read(urls, secret: secret) { url in metrics.record(url) }
        }
        let loadStart = Date()
        let viewer = JournalViewerModel(journal: f.store, calendar: f.calendar, now: f.now, clock: { f.now })
        await viewer.waitForLoad()
        #expect(viewer.items.count == 358)
        #expect(metrics.count == 28 && !metrics.usedMainThread)
        let loadSeconds = Date().timeIntervalSince(loadStart), filterStart = Date()
        for query in ["O", "Or", "Orc", "Orchid", ""] { viewer.search = query }
        print("Journal snapshot: 10000 items / 28 days, async load \(loadSeconds)s; five cached searches \(Date().timeIntervalSince(filterStart))s; physical reads \(metrics.count)")
        viewer.day = f.now.addingTimeInterval(-86400); viewer.level = 2; viewer.app = "test.editor"
        #expect(viewer.items.count == 358)
        #expect(metrics.count == 28)
        viewer.reload(); await viewer.waitForLoad()
        #expect(metrics.count == 28, "Explicit access revalidation reuses the same valid snapshot")
        try f.store.append(.init(time: f.now, level: .activity, kind: .activity, payload: .init(.init(description: "New activity"))))
        viewer.reload(); await viewer.waitForLoad()
        #expect(metrics.count == 56)
        #expect(viewer.error == nil)
    }

    @Test func erasedAndShortenedDataCannotReturnFromAnOlderDetachedRead() async throws {
        for erase in [true, false] {
            let f = try SnapshotFixture(); defer { f.remove() }
            try f.store.append(f.typing())
            let gate = SnapshotGate()
            f.store.snapshotRead = { urls, secret in
                let values = try await JournalSnapshotReader.read(urls, secret: secret)
                await gate.holdFirstRead()
                return values
            }
            let load = Task { try await f.store.journalSnapshot() }
            await gate.entered()
            if erase { try f.store.delete(.all) }
            else { try f.store.pruneTyping(words: .none, now: f.now) }
            await gate.release()
            let snapshot = try await load.value
            if erase { #expect(snapshot.items.isEmpty) }
            else { #expect(snapshot.items.count == 1 && snapshot.items[0].payload.value.text == nil) }
            #expect(snapshot.revision == f.store.revision)
        }
    }

    @Test func keyFailureOrReplacementInvalidatesCachedAndInflightSnapshots() async throws {
        for replacement in [false, true] {
            let f = try SnapshotFixture(); defer { f.remove() }
            try f.store.append(f.typing())
            let gate = SnapshotGate()
            f.store.snapshotRead = { urls, secret in
                let values = try await JournalSnapshotReader.read(urls, secret: secret)
                await gate.holdFirstRead(); return values
            }
            let load = Task { try await f.store.journalSnapshot() }
            await gate.entered()
            if replacement { f.key.bytes = Data(repeating: 13, count: 32) } else { f.key.unavailable = true }
            await gate.release()
            await #expect(throws: (any Error).self) { try await load.value }
            f.key.bytes = Data(repeating: 42, count: 32); f.key.unavailable = false
            #expect(try await f.store.journalSnapshot().items.count == 1)
            f.key.unavailable = true
            await #expect(throws: (any Error).self) { try await f.store.journalSnapshot() }
        }
    }

    @Test func initialExpiryScrubsDiskBeforeReturningWithoutASecondDecodeScan() async throws {
        let f = try SnapshotFixture(); defer { f.remove() }
        let old = f.typing(at: f.now.addingTimeInterval(-90000))
        let url = f.root.appendingPathComponent(f.day(old.time))
        try LearningEncryption.write([old], to: url, key: f.key)
        let metrics = SnapshotReads()
        f.store.snapshotRead = { urls, secret in
            try await JournalSnapshotReader.read(urls, secret: secret) { metrics.record($0) }
        }
        let value = try await f.store.journalSnapshot()
        #expect(value.items.count == 1 && value.items[0].payload.value.text == nil)
        let persisted = try #require(LearningEncryption.read([JournalItem].self, at: url, key: f.key))
        #expect(persisted[0].payload.value.text == nil)
        #expect(metrics.count == 1 && !metrics.usedMainThread)
        #expect(value.revision == 1)
    }

    @Test func initialRecoveryFinishesCommittedPartitionsBeforeDecode() async throws {
        let f = try SnapshotFixture(); defer { f.remove() }
        let item = f.typing()
        try LearningEncryption.write([String: [JournalItem]]([f.day(item.time): [item]]),
            to: f.root.appendingPathComponent("pending.ztransaction"), key: f.key)
        let value = try await f.store.journalSnapshot()
        #expect(value.items == [item])
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("pending.ztransaction").path))
    }

    @Test func partialExpiryWriteFailurePublishesNothingAndRetriesCommittedPartitions() async throws {
        let f = try SnapshotFixture(); defer { f.remove() }
        for offset in [90000.0, 180000.0] {
            let item = f.typing(at: f.now.addingTimeInterval(-offset))
            try LearningEncryption.write([item], to: f.root.appendingPathComponent(f.day(item.time)), key: f.key)
        }
        f.key.calls = 0; f.key.failAt = 4
        await #expect(throws: (any Error).self) { try await f.store.journalSnapshot() }
        #expect(f.store.revision == 1, "The first committed scrub remains a visible revision despite the second failure")
        f.key.failAt = nil
        let value = try await f.store.journalSnapshot()
        #expect(value.items.count == 2 && value.items.allSatisfy { $0.payload.value.text == nil })
        #expect(value.revision == 2)
    }

    @Test func expiryDuringDecodeIsAppliedAtPublication() async throws {
        let f = try SnapshotFixture(); defer { f.remove() }
        try f.store.append(f.typing())
        let gate = SnapshotGate()
        f.store.snapshotRead = { urls, secret in
            let values = try await JournalSnapshotReader.read(urls, secret: secret)
            await gate.holdFirstRead(); return values
        }
        let load = Task { try await f.store.journalSnapshot() }
        await gate.entered(); f.now.addTimeInterval(90000); await gate.release()
        let value = try await load.value
        #expect(value.items.count == 1 && value.items[0].payload.value.text == nil)
    }
}

private final class SnapshotReads: Sendable {
    private let state = Mutex((count: 0, main: false))
    func record(_ url: URL) { state.withLock { $0.count += 1; $0.main = $0.main || Thread.isMainThread } }
    var count: Int { state.withLock { $0.count } }
    var usedMainThread: Bool { state.withLock { $0.main } }
}

private actor SnapshotGate {
    private var held = false
    private var used = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func holdFirstRead() async {
        guard !used else { return }; used = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation; held = true; waiter?.resume(); waiter = nil
        }
    }
    func entered() async {
        if held { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class SnapshotKey: FixtureLearningKeyProviding {
    var bytes = Data(repeating: 42, count: 32)
    var unavailable = false
    var calls = 0
    var failAt: Int?
    func key() throws -> Data {
        calls += 1
        if calls == failAt { throw LearningStorageError.keyUnavailable }
        if unavailable { throw LearningStorageError.keyUnavailable }
        return bytes
    }
}

@MainActor private final class SnapshotFixture {
    let root: URL
    let key = SnapshotKey()
    var now = Date(timeIntervalSince1970: 1_792_339_200)
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current; return c }
    lazy var store = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar, clock: { [unowned self] in self.now })
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func day(_ date: Date) -> String { let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd'.zjournal'"; return f.string(from: date) }
    func typing(at date: Date? = nil) -> JournalItem {
        .init(id: "typing-\((date ?? now).timeIntervalSince1970)", time: date ?? now, level: .typed, app: "test.editor", kind: .typedText,
            payload: .init(.init(description: "Typing", text: "Synthetic words", topic: "Synthetic topic")))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
