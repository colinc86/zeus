import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct UserMessageLifecycleTests {
    @Test func queuedDeliveredAckedAndRecoveredAreObservableWithOneStableID() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let id = UserMessageDelivery.makeID()
        if case .queued = await f.runtime.sendUserMessage("Stable", deliveryID: id) {} else { Issue.record("Expected saved queue") }
        #expect(f.runtime.userMessageDeliveries.first?.id == id && f.runtime.userMessageDeliveries.first?.state == .queued)
        #expect(f.runtime.userMessageDeliveries.first?.recovered == false)
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.userMessageDeliveries.first?.recovered == true)
        let changed = ObservationFlag()
        withObservationTracking { _ = f.runtime.userMessageDeliveries } onChange: { changed.mark() }
        f.connect()
        try await eventually { f.runtime.userMessageDeliveries.first?.state == .delivered }
        #expect(changed.value && f.connector.deliveries.count == 1 && f.connector.deliveries.first?.id == id)
        #expect(await f.runtime.sendUserMessage("Stable", deliveryID: id) == .delivered)
        #expect(f.connector.deliveries.count == 1)
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]])
        #expect(f.runtime.userMessageDeliveries.first?.state == .acked)
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.userMessageDeliveries.first?.state == .acked && f.runtime.userMessageDeliveries.first?.recovered == true)
        #expect(await f.runtime.sendUserMessage("Stable", deliveryID: id) == .delivered)
        #expect(f.connector.deliveries.count == 1)
    }

    @Test func concurrentSendsCoalesceAndConflictingPayloadNeverReusesAnID() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect(); f.connector.hold = true
        let id = UserMessageDelivery.makeID()
        let first = Task { await f.runtime.sendUserMessage("One", deliveryID: id) }
        try await eventually { f.connector.waits.count == 1 }
        let second = Task { await f.runtime.sendUserMessage("One", deliveryID: id) }
        if case .failed = await f.runtime.sendUserMessage("Different", deliveryID: id) {} else { Issue.record("Expected ID conflict") }
        #expect(f.runtime.userMessageDeliveries.first?.state == .queued && f.connector.deliveries.count == 1)
        f.connector.release()
        #expect(await first.value == .delivered)
        #expect(await second.value == .delivered)
        #expect(f.runtime.ledger?.records.count == 1 && f.runtime.userMessageDeliveries.first?.text == "One")
    }

    @Test func discardedTombstoneSurvivesFreshRuntimeAndRejectsLateAckAndSend() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect(); f.connector.hold = true
        let id = UserMessageDelivery.makeID()
        let send = Task { await f.runtime.sendUserMessage("Discard", deliveryID: id) }
        try await eventually { f.connector.waits.count == 1 }
        f.runtime.discardPendingDeliveries()
        #expect(f.runtime.userMessageDeliveries.first?.state == .discarded)
        #expect(f.runtime.ledger?.record(id: id)?.delivery.ackedAt == nil)
        f.connector.release(); _ = await send.value
        #expect(f.runtime.userMessageDeliveries.first?.state == .discarded && f.runtime.assistantActivity == nil)
        #expect(await f.call("zeus_ack", ["delivery_ids": [.string(id)]]).structured?["acked"] == [])
        f.stop(remove: false)
        let fresh = try RuntimeFixture(directory: f.directory); defer { fresh.stop() }
        #expect(fresh.runtime.userMessageDeliveries.first?.state == .discarded && fresh.runtime.userMessageDeliveries.first?.recovered == true)
        fresh.connect(); fresh.runtime.retryPendingDeliveries()
        if case .failed = await fresh.runtime.sendUserMessage("Discard", deliveryID: id) {} else { Issue.record("Discard must not resend") }
        #expect(fresh.connector.deliveries.isEmpty)
        #expect(await fresh.call("zeus_get_responses").structured?["items"] == [])
    }

    @Test func unsavedFailureCanRetryTheSamePersistedUIIDAndNeverPublishesFalseQueue() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let id = UserMessageDelivery.makeID()
        try FileManager.default.createDirectory(at: f.runtime.ledgerURL, withIntermediateDirectories: true)
        if case .failed = await f.runtime.sendUserMessage("Retry storage", deliveryID: id) {} else { Issue.record("Expected disk failure") }
        #expect(f.runtime.userMessageDeliveries.isEmpty && f.connector.deliveries.isEmpty)
        try FileManager.default.removeItem(at: f.runtime.ledgerURL)
        if case .queued = await f.runtime.sendUserMessage("Retry storage", deliveryID: id) {} else { Issue.record("Expected saved retry") }
        #expect(f.runtime.userMessageDeliveries.first?.id == id && f.runtime.ledger?.records.count == 1)
    }

    @Test func pollingReceiptUpdatesOnlyAfterConsumptionAndAckWinsLateTransportReceipt() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect(); f.connector.hold = true
        let id = UserMessageDelivery.makeID()
        let send = Task { await f.runtime.sendUserMessage("Poll", deliveryID: id) }
        try await eventually { f.connector.waits.count == 1 }
        let result = await f.runtime.callTool("zeus_get_responses", arguments: [:], sessionKey: "claude:/assistant", deferResultCommit: true)
        #expect(result.structured?["items"]?[0]?["delivery_id"] == .string(id))
        #expect(f.runtime.userMessageDeliveries.first?.state == .queued)
        _ = try f.runtime.acknowledge(ids: [id], sessionKey: "claude:/assistant")
        #expect(f.runtime.userMessageDeliveries.first?.state == .acked)
        f.connector.release(); #expect(await send.value == .delivered)
        #expect(f.runtime.userMessageDeliveries.first?.state == .acked)
    }

    @Test func versionOneAttemptsAreRecoveredAsUnconfirmedQueueAndDiscardWritesVersionTwo() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.runtime.stop()
        let delivery = Delivery(id: "d_legacy", kind: .userMessage, sessionKey: "claude:/assistant#1.2", content: "Message from the user: Legacy", attempts: 1)
        let snapshot: JSONValue = ["version": 1, "records": [["delivery": try .from(delivery), "userText": "Legacy"]]]
        try ZeusJSON.encoder().encode(snapshot).write(to: f.runtime.ledgerURL)
        try f.runtime.start()
        #expect(f.runtime.userMessageDeliveries.first?.state == .queued && f.runtime.userMessageDeliveries.first?.recovered == true)
        #expect(f.runtime.userMessageDeliveries.first?.text == "Legacy")
        f.runtime.discardPendingDeliveries()
        let saved = try ZeusJSON.decoder().decode(JSONValue.self, from: Data(contentsOf: f.runtime.ledgerURL))
        #expect(saved["version"] == 2 && f.runtime.ledger?.record(id: "d_legacy")?.discardedAt != nil)
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.withLock { marked = true } }
    var value: Bool { lock.withLock { marked } }
}
