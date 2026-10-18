import Foundation
import Testing
@testable import Zeus

@MainActor private final class InterruptibleJournalKey: FixtureLearningKeyProviding {
    var calls = 0
    var failFrom: Int?
    func key() throws -> Data {
        calls += 1
        if let failFrom, calls >= failFrom { throw LearningStorageError.keyUnavailable }
        return Data(repeating: 19, count: 32)
    }
}

@Suite @MainActor struct JournalZoneTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("journal-zones-" + UUID().uuidString) }
    private func item(_ id: String, at time: Date) -> JournalItem {
        .init(id: id, time: time, level: .typed, app: "com.example.fixture", kind: .typedText,
              payload: .init(.init(description: "Synthetic topic", text: "Synthetic private words", topic: "Synthetic topic")))
    }
    @Test func travelDeletionAndUndoUseOriginalPartitionsIncludingMixedZoneGroups() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let now = date("2026-11-01T05:31:00Z"), time = now.addingTimeInterval(-60), key = FixtureJournalKey()
        let chicago = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Chicago"), clock: { now })
        try chicago.append(item("before-travel", at: time))
        let la = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Los_Angeles"), clock: { now })
        try la.append(item("after-travel", at: time))
        let before = try la.items(matching: .init())
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["2026-10-31.zjournal", "2026-11-01.zjournal"])
        var notifications = 0
        la.onJournalDeletion = { ids in
            notifications += 1
            #expect(ids == Set(before.map(\.id)))
            #expect((try? la.items(matching: .init()).isEmpty) == true)
        }
        let receipt = try la.deleteTyping(ids: Set(before.map(\.id)))
        #expect(notifications == 1)
        #expect(try chicago.items(matching: .init()).isEmpty)
        try la.restoreTyping(receipt)
        #expect(try la.items(matching: .init()) == before)
        for (name, id) in [("2026-11-01.zjournal", "before-travel"), ("2026-10-31.zjournal", "after-travel")] {
            let rows = try LearningEncryption.read([JournalItem].self, at: root.appendingPathComponent(name), key: key)
            #expect(rows?.map(\.id) == [id])
        }
        la.onJournalDeletion = nil
        let single = try la.deleteTyping(ids: ["before-travel"])
        #expect(try la.items(matching: .init()).map(\.id) == ["after-travel"])
        try la.restoreTyping(single); #expect(try la.items(matching: .init()) == before)
    }
    @Test(arguments: [false, true])
    func framePairAcrossPartitionsDeletesAndRestoresAtomically(includingDescription: Bool) throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let now = date("2026-11-01T05:31:00Z"), key = FixtureJournalKey()
        let chicago = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Chicago"), clock: { now })
        let la = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Los_Angeles"), clock: { now })
        let picture = Redacted(FrameItem(heic: Data([1, 2, 3]), width: 10, height: 10, boxes: [], appName: "Fixture", windowTitle: "Synthetic"))
        let frame = JournalItem(id: "frame", time: now, level: .screen, kind: .frame, payload: .init(.init(description: "Synthetic picture")))
        let description = JournalItem(id: "description", time: now, level: .screen, kind: .description,
                                      payload: .init(.init(description: "Synthetic description", details: ["frame_id": frame.id])))
        try chicago.appendFrame(picture, item: frame); try la.append(description)
        let before = try la.items(matching: .init())
        var notified = false
        la.onJournalDeletion = { _ in
            notified = true
            #expect((try? la.frame(id: "frame")) == nil)
            #expect((try? la.items(matching: .init()).count) == (includingDescription ? 0 : 1))
        }
        let receipt = try la.deleteFrame(id: "frame", includingDescription: includingDescription)
        #expect(notified)
        if !includingDescription {
            #expect(try la.items(matching: .init()).first?.payload.value.details["picture_not_kept"] == "deletedByUser")
        }
        try la.restoreFrame(receipt)
        #expect(try la.items(matching: .init()) == before); #expect(try la.frame(id: "frame") == picture)
        #expect(try LearningEncryption.read([JournalItem].self, at: root.appendingPathComponent("2026-11-01.zjournal"), key: key) == [frame])
        #expect(try LearningEncryption.read([JournalItem].self, at: root.appendingPathComponent("2026-10-31.zjournal"), key: key) == [description])
    }
    @Test func interruptionAtEveryKeyAccessNeverExposesHalfAGroup() throws {
        var sawCommittedInterruption = false, sawPrecommitFailure = false
        for access in 1...30 {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let now = date("2026-11-01T05:31:00Z"), key = InterruptibleJournalKey()
            let chicago = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Chicago"), clock: { now })
            let la = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Los_Angeles"), clock: { now })
            try chicago.append(item("one", at: now)); try la.append(item("two", at: now))
            _ = try la.items(matching: .init())
            var notified = false, succeeded = false
            la.onJournalDeletion = { _ in notified = true }
            key.calls = 0; key.failFrom = access
            do { _ = try la.deleteTyping(ids: ["one", "two"]); succeeded = true }
            catch { sawPrecommitFailure = true }
            let pending = FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.ztransaction").path)
            if pending {
                sawCommittedInterruption = true
                #expect(succeeded && notified)
                #expect(throws: (any Error).self) { try la.items(matching: .init()) }
            }
            #expect(notified == succeeded)
            key.failFrom = nil
            let reopened = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Los_Angeles"), clock: { now })
            #expect(try reopened.items(matching: .init()).count == (succeeded ? 0 : 2))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.ztransaction").path))
        }
        #expect(sawCommittedInterruption && sawPrecommitFailure)
    }
    @Test func forgetAllRemovesAnInterruptedCommitWithoutNeedingItsKey() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let now = date("2026-11-01T05:31:00Z"), key = InterruptibleJournalKey()
        let store = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Chicago"), clock: { now })
        try store.append(item("original", at: now))
        try LearningEncryption.write(["2026-11-01.zjournal": [item("undo-pending", at: now)]], to: root.appendingPathComponent("pending.ztransaction"), key: key)
        key.failFrom = 0
        try store.delete(.all)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        key.failFrom = nil; #expect(try store.items(matching: .init()).isEmpty)
    }
    @Test func travellingRetentionAndAppErasureRewritePhysicalFiles() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let now = date("2026-11-01T05:31:00Z"), key = FixtureJournalKey()
        let chicago = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Chicago"), clock: { now })
        try chicago.append(item("words", at: now))
        let la = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar("America/Los_Angeles"), clock: { now })
        try la.pruneTyping(words: .none, now: now)
        #expect(try la.items(matching: .init()).first?.payload.value.text == nil)
        try la.delete(.app("com.example.fixture"))
        #expect(try chicago.items(matching: .init()).isEmpty)
    }
}
