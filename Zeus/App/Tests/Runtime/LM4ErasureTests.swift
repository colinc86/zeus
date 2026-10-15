import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct LM4ErasureTests {
    @Test func eraseAllDiscardsQueuedLearningAndLateToolReceiptAcrossRestart() async throws {
        let provider = FakeLearnings(), f = try LearningRuntimeFixture(learnings: provider)
        defer { f.stop() }
        f.connector.available = false
        let note = Learning(id: "erase-note", kind: .moment, createdAt: f.clock.now, text: "Private synthetic note")
        provider.add(note)
        try await eventually { f.runtime.ledger?.record(id: note.id) != nil }
        let prepared = await f.runtime.callTool("zeus_get_learnings", arguments: [:], sessionKey: "claude:/fixture#123.1", deferResultCommit: true)
        #expect(!prepared.isError)
        try f.journal.delete(.all)
        #expect(f.runtime.pendingLearningDeliveries.isEmpty)
        #expect(f.runtime.ledger?.record(id: note.id)?.discardedAt == f.clock.now)
        #expect(f.runtime.ledger?.record(id: note.id)?.delivery.content == "")
        f.clock.advance(601, wake: false)
        f.connector.available = true; f.runtime.processDueDeliveries()
        #expect(try f.runtime.acknowledge(ids: [note.id], sessionKey: "claude:/fixture#123.1").isEmpty)
        f.runtime.recordLearningToolReceipts([try JSONValue.from(note)], sessionKey: "claude:/fixture#123.1")
        f.runtime.stop(); try f.runtime.start()
        f.runtime.recordSentLearning(id: note.id, kind: "moment", text: .init(note.text), sessionKey: "claude:/fixture#123.1")
        #expect(f.connector.deliveries.isEmpty && f.runtime.pendingLearningDeliveries.isEmpty)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        #expect(f.cards.learningNotices.isEmpty)
        let result = await f.runtime.callTool("zeus_get_learnings", arguments: [:], sessionKey: "claude:/fixture#123.1")
        #expect(result.structured?["learnings"] == [])
    }

    @Test func deletingOneEvidenceCancelsInFlightReflectionButKeepsUnrelatedLearning() async throws {
        let provider = FakeLearnings(), f = try LearningRuntimeFixture(learnings: provider)
        defer { f.connector.release(); f.stop() }
        try f.journal.append(.init(id: "focus-evidence", time: f.clock.now, level: .focus, kind: .focus, payload: .init(.init(description: "Synthetic"))))
        var reflection = Delivery(id: "erase-reflection", kind: .reflection, sessionKey: "claude:/fixture#123.1", content: "Synthetic reflection", createdAt: f.clock.now)
        reflection.meta["evidence"] = "focus-evidence"
        f.connector.hold = true
        try f.runtime.ledger?.insert(.init(delivery: reflection))
        let send = try #require(f.runtime.beginSend(id: reflection.id))
        try await eventually { !f.connector.waits.isEmpty }
        try f.journal.delete(.item("focus-evidence"))
        #expect(send.isCancelled && f.runtime.sends[reflection.id] == nil)
        #expect(f.runtime.ledger?.record(id: reflection.id)?.discardedAt == f.clock.now)
        f.connector.hold = false; f.connector.release(); _ = await send.value
        #expect(try f.runtime.acknowledge(ids: [reflection.id], sessionKey: reflection.sessionKey).isEmpty)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        provider.add(.init(id: "keep-new", kind: .moment, createdAt: f.clock.now, text: "New note"))
        try await eventually { f.connector.deliveries.contains { $0.id == "keep-new" } }
        _ = try f.runtime.acknowledge(ids: ["keep-new"], sessionKey: reflection.sessionKey)
        #expect(try f.journal.items(matching: .init()).filter { $0.kind == .sentToAssistant }.count == 1)
    }

    @Test func erasedManagedPasteIsNeverSubmittedAndItsLateAckRecordsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm4-erased-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        let f = try ManagedDeliveryFixture(journal: journal); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let pane = try #require(f.managed.controller.record?.pane)
        let key = try #require(f.managed.controller.sessionKey)
        var delivery = Delivery(id: "erased-paste", kind: .learning, sessionKey: key, content: "Already pasted synthetic text", createdAt: f.managed.clock.now)
        delivery.attempts = 5; delivery.failedAt = f.managed.clock.now
        delivery.meta["tmux_paste_destination"] = pane.socket + ":" + pane.id
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        try journal.delete(.all)
        f.managed.clock.advance(601, wake: false); f.runtime.processDueDeliveries()
        #expect(f.runtime.beginSend(id: delivery.id) == nil)
        #expect(f.tmux.deliveries.isEmpty)
        #expect(try f.runtime.acknowledge(ids: [delivery.id], sessionKey: key).isEmpty)
        f.runtime.recordReflectionReceipt(id: delivery.id)
        #expect(try journal.items(matching: .init()).isEmpty)
        #expect(f.runtime.pendingLearningDeliveries.isEmpty && f.runtime.deliveryHolds.isEmpty)
        // Erasure performed no connector call, paste, submit, or native cancellation.
        #expect(f.managed.controller.record?.pane == pane)
    }

    @Test func eraseAfterAcknowledgmentNeverReplaysReceiptOnRelaunch() async throws {
        let provider = FakeLearnings(), f = try LearningRuntimeFixture(learnings: provider)
        defer { f.stop() }
        provider.add(.init(id: "acked-before-delete", kind: .digest, createdAt: f.clock.now, text: "Synthetic"))
        try await eventually { f.connector.deliveries.count == 1 }
        _ = try f.runtime.acknowledge(ids: ["acked-before-delete"], sessionKey: "claude:/fixture#123.1")
        #expect(try f.journal.items(matching: .init()).count == 1)
        try f.journal.delete(.all)
        f.runtime.stop(); try f.runtime.start()
        f.runtime.recordReflectionReceipt(id: "acked-before-delete")
        #expect(try f.journal.items(matching: .init()).isEmpty)
        #expect(f.runtime.ledger?.record(id: "acked-before-delete")?.discardedAt != nil)
    }

    @Test func storeResetDiscardsWithoutMistakingReadForDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm4-source-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LearningsStore(files: ActivityStore(root: root), isEnabled: { true })
        let f = try LearningRuntimeFixture(learnings: source); defer { f.stop() }
        f.connector.available = false
        source.add(.digest, text: "Synthetic summary", at: f.clock.now)
        let id = try #require(source.learnings.first?.id)
        try await eventually { f.runtime.ledger?.record(id: id) != nil }
        source.markLearningRead(id: id)
        #expect(f.runtime.ledger?.record(id: id)?.isPending == true)
        source.reset()
        #expect(f.runtime.ledger?.record(id: id)?.discardedAt != nil)
        #expect(f.runtime.pendingLearningDeliveries.isEmpty)
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.pendingLearningDeliveries.isEmpty)
        #expect(try f.runtime.acknowledge(ids: [id], sessionKey: "claude:/fixture#123.1").isEmpty)
    }
}
