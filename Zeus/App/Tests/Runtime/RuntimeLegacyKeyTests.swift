import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct RuntimeLegacyKeyTests {
    @Test(arguments: ["claude:/old", "claude:/old#%7"])
    func loadedLegacyMessageWaitsForAutoAssistantAndKeepsItsIDAndPollingText(_ legacyKey: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let delivery = Delivery(kind: .userMessage, sessionKey: legacyKey, content: "Message from the user: Keep me",
                                meta: ["kind": "userMessage", "custom": "preserved"], createdAt: f.clock.now,
                                attempts: 5, lastAttemptAt: f.clock.now, failedAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery, userText: "Keep me"))
        f.runtime.stop(); try f.runtime.start()
        let waiting = try #require(DeliveryLedger(location: f.runtime.ledgerURL).record(id: delivery.id))
        #expect(waiting.awaitingAssistant == true && waiting.delivery.sessionKey.isEmpty)
        #expect(waiting.delivery.attempts == 0 && waiting.delivery.lastAttemptAt == nil && waiting.delivery.failedAt == nil)
        #expect(waiting.delivery.id == delivery.id && waiting.delivery.content == delivery.content)
        #expect(waiting.delivery.meta == delivery.meta && waiting.delivery.createdAt == delivery.createdAt)
        #expect(waiting.userText == "Keep me" && f.connector.deliveries.isEmpty)
        // The waiting state survives another load without falling back to its old key.
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.record(id: delivery.id) == waiting)
        f.routing.preferredAgent = .codex
        f.connect("claude:/other#100.200")
        #expect(f.runtime.ledger?.record(id: delivery.id)?.awaitingAssistant == true)
        let currentKey = "codex:/new#123.456"
        f.connector.onSend = { sent in
            let saved = try? DeliveryLedger(location: f.runtime.ledgerURL).record(id: sent.id)
            #expect(saved?.delivery.sessionKey == currentKey && saved?.awaitingAssistant == nil)
        }
        f.connect(currentKey, channel: false, agent: .codex)
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries.first?.id == delivery.id && f.connector.deliveries.first?.sessionKey == currentKey)
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == nil)
        let oldPoll = await f.call("zeus_get_responses", session: legacyKey)
        #expect(oldPoll.structured?["items"] == [])
        let poll = await f.call("zeus_get_responses", session: currentKey)
        #expect(poll.structured?["items"]?[0]?["delivery_id"] == .string(delivery.id))
        #expect(poll.structured?["items"]?[0]?["text"] == "Keep me")
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == f.clock.now)
    }

    @Test func legacyMigrationUsesExplicitAssistantAndLeavesRepliesAcknowledgedAndModernMessagesAlone() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let currentKey = "claude:/current#321.654"
        f.routing.assistantSessionKey = currentKey
        f.routing.deliveryMethod = .polling
        let legacy = DeliveryRecord(delivery: Delivery(kind: .userMessage, sessionKey: "claude:/old#%2", content: "Retarget", createdAt: f.clock.now), userText: "Retarget")
        let controls = [
            DeliveryRecord(delivery: Delivery(kind: .reply, cardID: "c_old0001", sessionKey: "claude:/old", content: "Keep reply", createdAt: f.clock.now), disconnectedAt: f.clock.now),
            DeliveryRecord(delivery: Delivery(kind: .userMessage, sessionKey: "claude:/old", content: "Already read", createdAt: f.clock.now, ackedAt: f.clock.now)),
            DeliveryRecord(delivery: Delivery(kind: .userMessage, sessionKey: "claude:/folder#tag#123.456", content: "Modern", createdAt: f.clock.now, attempts: 2, lastAttemptAt: f.clock.now)),
        ]
        for record in [legacy] + controls { try f.runtime.ledger?.insert(record) }
        f.runtime.stop(); try f.runtime.start()
        var expected = legacy; expected.delivery.sessionKey = currentKey; expected.stateUpdatedAt = f.clock.now
        #expect(f.runtime.ledger?.record(id: legacy.delivery.id) == expected)
        for record in controls { #expect(f.runtime.ledger?.record(id: record.delivery.id) == record) }
        let persisted = try DeliveryLedger(location: f.runtime.ledgerURL)
        #expect(persisted.record(id: legacy.delivery.id) == expected)
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.record(id: legacy.delivery.id) == expected)
        f.connect("claude:/unselected#111.222")
        #expect(f.runtime.ledger?.record(id: legacy.delivery.id) == expected && f.connector.deliveries.isEmpty)
        f.connect(currentKey)
        let poll = await f.call("zeus_get_responses", session: currentKey)
        #expect(poll.structured?["items"]?[0]?["delivery_id"] == .string(legacy.delivery.id))
    }
}
