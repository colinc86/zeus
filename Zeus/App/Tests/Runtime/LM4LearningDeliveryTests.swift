import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct LM4LearningDeliveryTests {
    @Test func managedLearningRoundTripRecordsOnlyTheModelAck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm4-managed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        let provider = FakeLearnings()
        let f = try ManagedDeliveryFixture(learnings: provider, journal: journal); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        provider.add(.init(id: "managed-digest", kind: .digest, createdAt: f.managed.clock.now, text: "Synthetic managed summary"))
        try await eventually { f.tmux.deliveries.count == 1 }
        #expect(try journal.items(matching: .init()).isEmpty)
        let delivery = try #require(f.tmux.deliveries.first)
        _ = try f.runtime.acknowledge(ids: [delivery.id], sessionKey: delivery.sessionKey)
        let receipt = try #require(journal.items(matching: .init()).first)
        #expect(receipt.kind == .sentToAssistant && receipt.payload.value.text == delivery.content)
        #expect(receipt.payload.value.details["sessionLabel"] == "Claude · Zeus")
        #expect(provider.unreadLearnings().isEmpty)
    }
    @Test func offlineLearningSurvivesRestartAndOnlyAckCreatesReceipt() async throws {
        let provider = FakeLearnings(), f = try LearningRuntimeFixture(learnings: provider)
        defer { f.stop() }
        let old = try #require(f.runtime.sessions.first)
        f.runtime.unregisterSession(id: old.id, sessionKey: old.sessionKey)
        provider.add(.init(id: "lm4-digest", kind: .digest, createdAt: f.clock.now, text: "Synthetic daily summary"))
        try await eventually { f.runtime.ledger?.record(id: "lm4-digest") != nil }
        #expect(f.runtime.pendingLearningDeliveries.first?.learningKind == .digest)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        f.runtime.stop(); try f.runtime.start()
        f.runtime.registerSession(.init(id: UUID(), sessionKey: "claude:/fixture#123.1", agent: .claude, cwd: "/fixture", clientName: nil, supportsChannel: true, tmuxPane: nil, connectedAt: f.clock.now))
        try await eventually { f.connector.deliveries.contains { $0.id == "lm4-digest" } }
        #expect(try f.journal.items(matching: .init()).isEmpty)
        _ = try f.runtime.acknowledge(ids: ["lm4-digest"], sessionKey: "claude:/fixture#123.1")
        _ = try f.runtime.acknowledge(ids: ["lm4-digest"], sessionKey: "claude:/fixture#123.1")
        let receipts = try f.journal.items(matching: .init()).filter { $0.kind == .sentToAssistant }
        #expect(receipts.count == 1 && receipts.first?.payload.value.text == "Synthetic daily summary")
        #expect(provider.readIDs == ["lm4-digest"] && f.runtime.pendingLearningDeliveries.isEmpty)
        #expect(f.cards.learningNotices.contains { $0.id == "n_lm4-digest" })
    }
    @Test func outOfOrderAckNeverConsumesEarlierLearning() async throws {
        let provider = FakeLearnings(), f = try LearningRuntimeFixture(learnings: provider); defer { f.stop() }
        for id in ["one", "two"] { provider.add(.init(id: id, kind: .moment, createdAt: f.clock.now, text: id)) }
        try await eventually { f.connector.deliveries.count == 2 }
        _ = try f.runtime.acknowledge(ids: ["two"], sessionKey: "claude:/fixture#123.1")
        #expect(provider.readIDs.isEmpty)
        _ = try f.runtime.acknowledge(ids: ["one"], sessionKey: "claude:/fixture#123.1")
        #expect(provider.readIDs == ["two"])
    }
    @Test func draftHoldAppearsAfterTenMinutesAndClearSendsImmediately() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        let helper = ManagedDraftAlertTests()
        try await helper.ready(f)
        _ = await f.runtime.sendUserMessage("Waiting", deliveryID: "lm4-held")
        f.managed.clock.advance(599, wake: false); try await helper.sample(f, helper.draft())
        #expect(f.runtime.deliveryHolds.isEmpty)
        f.managed.clock.advance(1, wake: false); try await helper.sample(f, helper.draft())
        #expect(f.runtime.deliveryHolds.first?.reason == .draft)
        #expect(f.runtime.deliveryHolds.first?.deliveryID == "lm4-held")
        try await f.idle()
        try await eventually { f.tmux.deliveries.count == 1 }
        #expect(f.runtime.deliveryHolds.isEmpty)
    }
    @Test func learningRetargetsOnlyAfterOldLifetimeIsProvenDead() async throws {
        let base = try RuntimeFixture(); defer { base.stop() }
        base.runtime.stop()
        var dead = false
        let runtime = ZeusRuntime(cards: base.cards, status: base.status, characters: base.characters, routing: base.routing,
            clock: base.clock, socketPath: base.directory.appendingPathComponent("replacement.sock").path,
            ledgerURL: base.directory.appendingPathComponent("replacement.json"), connectors: [base.connector], targetIsDead: { _ in dead })
        try runtime.start(); defer { runtime.stop() }
        var delivery = Delivery(id: "retarget-learning", kind: .learning, sessionKey: "claude:/old#1.1", content: "Synthetic", createdAt: base.clock.now)
        delivery.attempts = 5; delivery.failedAt = base.clock.now
        try runtime.ledger?.insert(.init(delivery: delivery))
        runtime.retargetDeadUserMessages()
        #expect(runtime.ledger?.record(id: delivery.id)?.delivery.sessionKey == "claude:/old#1.1")
        dead = true; runtime.retargetDeadUserMessages()
        #expect(runtime.ledger?.record(id: delivery.id)?.awaitingAssistant == true)
        runtime.registerSession(.init(id: UUID(), sessionKey: "claude:/new#2.2", agent: .claude, cwd: "/new", clientName: nil, supportsChannel: true, tmuxPane: nil, connectedAt: base.clock.now))
        let record = try #require(runtime.ledger?.record(id: delivery.id))
        #expect(record.delivery.sessionKey == "claude:/new#2.2" && record.delivery.failedAt == nil)
    }
    @Test func learningCancellationAlwaysConfirmsOneAndNeverCancelsLaterMessage() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        let helper = ManagedDraftAlertTests(); try await helper.ready(f)
        let key = try #require(f.managed.controller.sessionKey)
        try f.runtime.ledger?.insert(.init(delivery: .init(id: "cancel-note", kind: .learning, sessionKey: key, content: "Synthetic", createdAt: f.managed.clock.now)))
        f.runtime.processDueDeliveries(); try await helper.wait20(f)
        f.runtime.requestLearningDeliveryCancellation(deliveryID: "cancel-note")
        let request = try #require(f.runtime.managedDraftCancellation)
        #expect(request.count == 1 && f.runtime.ledger?.record(id: "cancel-note")?.isPending == true)
        _ = await f.runtime.sendUserMessage("Later message", deliveryID: "keep-message")
        f.runtime.respondToDraftCancellation(id: request.id, confirmed: true)
        #expect(f.runtime.ledger?.record(id: "cancel-note")?.discardedAt != nil)
        #expect(f.runtime.ledger?.record(id: "keep-message")?.isPending == true)
        #expect(f.tmux.deliveries.isEmpty)
    }
    @Test func exactStoreConsumptionSurvivesReopenWithoutEatingEarlierNote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lm4-read-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ActivityStore(root: folder)
        let store = LearningsStore(files: files, isEnabled: { true })
        store.add(.moment, text: "First", at: Date()); store.add(.digest, text: "Second", at: Date())
        let values = store.unreadLearnings()
        store.markLearningRead(id: values[1].id)
        let reopened = LearningsStore(files: files, isEnabled: { true })
        #expect(reopened.unreadLearnings().map(\.id) == [values[0].id])
    }
    @Test func disconnectedHoldPersistsAcrossRuntimeRestart() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        _ = await f.runtime.sendUserMessage("Offline", deliveryID: "lm4-offline")
        f.clock.advance(601, wake: false); f.runtime.processDueDeliveries()
        #expect(f.runtime.deliveryHolds.first?.reason == .disconnected)
        let since = f.runtime.deliveryHolds.first?.since
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.deliveryHolds.first?.since == since)
    }
}
