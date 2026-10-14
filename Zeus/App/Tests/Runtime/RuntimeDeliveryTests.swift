import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct RuntimeDeliveryTests {
    @Test func durableUserRoutingAndSessionScopedExplicitAck() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        if case .queued = await f.runtime.sendUserMessage("Hello") {} else { Issue.record("Expected a durable queue without an assistant") }
        f.runtime.discardPendingDeliveries()
        f.connect("claude:/older"); f.connect("claude:/newer")
        f.connector.onSend = { delivery in
            let persisted = try? DeliveryLedger(location: f.runtime.ledgerURL).record(id: delivery.id)
            #expect(persisted?.delivery == delivery)
            #expect(delivery.attempts == 1)
        }
        #expect(await f.runtime.sendUserMessage("Hello ⚡") == .delivered)
        let delivery = try #require(f.connector.deliveries.first)
        #expect(delivery.sessionKey == "claude:/newer")
        #expect(delivery.content == "Message from the user: Hello ⚡")
        #expect(delivery.meta == ["kind": "userMessage", "delivery_id": delivery.id])
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == nil)
        let foreign = await f.call("zeus_ack", ["delivery_ids": [.string(delivery.id)]], session: "claude:/older")
        #expect(foreign.structured == ["acked": []])
        let ack = await f.call("zeus_ack", ["delivery_ids": [.string(delivery.id)]], session: "claude:/newer")
        #expect(ack.structured == ["acked": [.string(delivery.id)]])
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == f.clock.now)
        f.clock.advance(3600)
        await Task.yield()
        #expect(f.connector.deliveries.count == 1 && f.status.problem == nil)
        f.routing.assistantSessionKey = "claude:/offline"
        if case .queued = await f.runtime.sendUserMessage("Designated") { } else { Issue.record("Expected queued") }
        #expect(f.runtime.ledger?.records.last?.delivery.sessionKey == "claude:/offline")
    }

    @Test func pendingReplyFormatsAndImplicitAckRequiresTarget() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect()
        let pending = await f.call("zeus_ask", ["text": "Have you started on the presentation?", "wait_seconds": 0])
        #expect(pending.structured?["status"] == "pending")
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, option: "no", label: "No", text: "I haven't.")
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        let delivery = try #require(f.connector.deliveries.first)
        #expect(delivery.content == "Reply to \"Have you started on the presentation?\": No\nI haven't.")
        #expect(delivery.meta == ["kind": "reply", "delivery_id": delivery.id, "card_id": card.id, "option_id": "no"])
        _ = await f.call("zeus_update_card", ["card_id": .string(card.id), "text": "Done"], session: "claude:/other")
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == nil)
        _ = await f.call("zeus_update_card", ["card_id": .string(card.id), "text": "Done"])
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == f.clock.now)
        #expect(f.status.problem == nil)
    }

    @Test func pollingAcksOnlyItsItemsAndPreservesAnswerAfterHistoryPruning() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        _ = await f.call("zeus_ask", ["text": "Started?", "wait_seconds": 0])
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, option: "yes", label: "Yes", text: "Today", device: .ios)
        _ = await f.call("zeus_ask", ["text": "Other?", "wait_seconds": 0], session: "claude:/other")
        let other = try #require(f.cards.values.last)
        f.cards.respond(id: other.id, text: "Other answer")
        f.cards.values.removeAll()
        let deliveries = try #require(f.runtime.ledger?.records)
        let response = await f.call("zeus_get_responses")
        #expect(response.structured?["items"] == [[
            "delivery_id": .string(deliveries[0].delivery.id), "kind": "reply", "card_id": .string(card.id),
            "option_id": "yes", "option_label": "Yes", "text": "Today", "created_at": "2023-11-14T22:13:20.000Z"
        ]])
        #expect(f.runtime.ledger?.record(id: deliveries[0].delivery.id)?.delivery.ackedAt != nil)
        #expect(f.runtime.ledger?.record(id: deliveries[1].delivery.id)?.delivery.ackedAt == nil)
        #expect(await f.call("zeus_get_responses").structured?["items"] == [])
    }

    @Test func retryBackoffStopsAfterFiveAttemptsAndFailureRemainsPollable() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect()
        #expect(await f.runtime.sendUserMessage("Hello") == .delivered)
        let id = try #require(f.runtime.ledger?.records.first?.delivery.id)
        f.clock.advance(179)
        await Task.yield()
        #expect(f.connector.deliveries.count == 1)
        f.clock.advance(1)
        try await eventually { f.connector.deliveries.count == 2 && f.runtime.sends.isEmpty }
        for interval in [360.0, 720.0, 1440.0] {
            let count = f.connector.deliveries.count
            f.clock.advance(interval - 1)
            await Task.yield()
            #expect(f.connector.deliveries.count == count)
            f.clock.advance(1)
            try await eventually { f.connector.deliveries.count == count + 1 && f.runtime.sends.isEmpty }
        }
        let failed = try #require(f.runtime.ledger?.record(id: id)?.delivery)
        #expect(failed.attempts == 5 && failed.failedAt == f.clock.now && failed.ackedAt == nil)
        #expect(f.status.problem == ZeusRuntime.deliveryProblemText)
        f.clock.advance(10000)
        await Task.yield()
        #expect(f.connector.deliveries.count == 5)
        let polled = await f.call("zeus_get_responses")
        #expect(polled.structured?["items"]?[0]?["delivery_id"] == .string(id))
        #expect(f.status.problem == nil)
    }

    @Test func failedTransportUsesBackoffAndDoesNotCreateOverlappingSends() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect(); f.connector.fails = true
        if case .queued = await f.runtime.sendUserMessage("Retry") { } else { Issue.record("Expected queued") }
        #expect(f.connector.deliveries.count == 1 && f.status.problem == nil)
        f.connector.fails = false
        f.clock.advance(180)
        try await eventually { f.connector.deliveries.count == 2 && f.runtime.sends.isEmpty }
        #expect(f.status.problem == nil)
        let id = try #require(f.runtime.ledger?.records.first?.delivery.id)
        f.connector.hold = true
        let first = try #require(f.runtime.beginSend(id: id))
        let second = try #require(f.runtime.beginSend(id: id))
        try await eventually { f.connector.deliveries.count == 3 }
        #expect(f.runtime.sends.count == 1)
        f.connector.release()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult == .delivered && secondResult == .delivered)
    }

    @Test func disconnectWaitsWithoutBurningAttemptsAndReconnectFlushesImmediately() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.assistantSessionKey = "claude:/assistant"
        if case .queued = await f.runtime.sendUserMessage("Queued") { } else { Issue.record("Expected queued") }
        #expect(f.runtime.ledger?.records.first?.delivery.attempts == 0)
        f.clock.advance(1000)
        await Task.yield()
        #expect(f.connector.deliveries.isEmpty)
        let bridgeID = UUID()
        f.connect(id: bridgeID)
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        f.runtime.unregisterSession(id: bridgeID, sessionKey: "claude:/assistant")
        f.clock.advance(2000)
        await Task.yield()
        #expect(f.connector.deliveries.count == 1)
        f.connect()
        try await eventually { f.connector.deliveries.count == 2 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries[0].id == f.connector.deliveries[1].id)
    }

    @Test func ledgerReloadPreservesDeliveryAndPollingFields() async throws {
        let first = try RuntimeFixture()
        defer { first.stop() }
        _ = await first.call("zeus_ask", ["text": "Ready?", "wait_seconds": 0])
        let card = try #require(first.cards.values.first)
        first.cards.respond(id: card.id, option: "yes", label: "Yes", text: "Ready", device: .ios)
        let record = try #require(first.runtime.ledger?.records.first)
        first.stop(remove: false)
        let restarted = try RuntimeFixture(directory: first.directory)
        defer { restarted.stop() }
        #expect(restarted.runtime.ledger?.records.first == record)
        restarted.connect()
        try await eventually { restarted.connector.deliveries.count == 1 && restarted.runtime.sends.isEmpty }
        #expect(restarted.connector.deliveries.first?.id == record.delivery.id)
        let result = await restarted.call("zeus_get_responses")
        #expect(result.structured?["items"]?[0]?["option_label"] == "Yes")
        #expect(result.structured?["items"]?[0]?["text"] == "Ready")
        restarted.stop(remove: false)
        let reloaded = try DeliveryLedger(location: restarted.runtime.ledgerURL)
        #expect(reloaded.records.first?.delivery.ackedAt != nil)
    }

    @Test func pollingOnlyTargetDoesNotAttemptPush() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connector.available = false; f.connect(channel: false, agent: .codex)
        if case .queued = await f.runtime.sendUserMessage("Auto now finds Codex") { } else { Issue.record("Expected polling queue") }
        _ = await f.call("zeus_get_responses")
        f.routing.assistantSessionKey = "claude:/assistant"
        if case .queued = await f.runtime.sendUserMessage("Poll me") { } else { Issue.record("Expected polling queue") }
        #expect(f.connector.deliveries.isEmpty && f.runtime.ledger?.records.first?.delivery.attempts == 0)
        let polled = await f.call("zeus_get_responses")
        #expect(polled.structured?["items"]?[0]?["kind"] == "userMessage")
        #expect(polled.structured?["items"]?[0]?["text"] == "Poll me")
    }
}
