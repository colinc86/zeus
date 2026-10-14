import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct AgentErgonomicsTests {
    @Test func missingCardsAreErrorsAndSuccessfulMutationsEchoActualState() async throws {
        let f = try RuntimeFixture(appControl: FakeAppControl()); defer { f.stop() }
        for tool in ["zeus_update_card", "zeus_dismiss"] {
            let failure = await f.call(tool, ["card_id": "c_missing"])
            #expect(failure.isError && failure.structured?["error"] != nil)
        }
        let say = await f.call("zeus_say", ["text": "Start"])
        let id = try #require(say.structured?["card_id"])
        _ = await f.call("zeus_set_status", ["state": "working", "progress": 0.8])
        let update = await f.call("zeus_update_card", ["card_id": id, "append_text": "\nEnd", "progress": 0.25])
        #expect(update.structured == ["ok": true, "title": nil, "progress": 0.25, "status": "open"])
        #expect(f.cards.values.first?.body == "Start\nEnd" && f.status.progress == 0.8)
        let character = try #require(f.characters.availableCharacters.last?.id)
        let changed = await f.call("zeus_set_character", ["id": .string(character)])
        #expect(changed.structured == ["ok": true, "previous": "zeus", "current": .string(character)])
    }

    @Test func pollReportsThisSessionsConfiguredTransportAndAvailability() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let absent = await f.call("zeus_get_responses")
        #expect(absent.structured?["delivery_mode"] == "polling" && absent.structured?["push_active"] == false)
        f.connect(); f.routing.deliveryMethod = .tmux
        let connected = await f.call("zeus_get_responses")
        #expect(connected.structured?["delivery_mode"] == "tmux" && connected.structured?["push_active"] == true)
        f.routing.deliveryMethod = .polling
        let poll = await f.call("zeus_get_responses")
        #expect(poll.structured?["delivery_mode"] == "polling" && poll.structured?["push_active"] == false)
    }

    @Test func ledgerCapsTerminalHistoryButNeverDropsPendingOrExhaustedInput() throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let records = (0..<650).map { index in
            DeliveryRecord(delivery: Delivery(id: "d_\(index)", kind: .userMessage, sessionKey: "claude:/assistant", content: "\(index)",
                                            createdAt: f.clock.now.addingTimeInterval(Double(index)), ackedAt: index < 3 ? nil : f.clock.now,
                                            failedAt: index == 1 ? f.clock.now : nil), userText: "\(index)")
        }
        try f.runtime.ledger?.mutateRecords { $0 = records }
        #expect(f.runtime.ledger?.records.count == 503)
        #expect(f.runtime.ledger?.record(id: "d_1")?.delivery.failedAt != nil)
        #expect(f.runtime.ledger?.record(id: "d_149") == nil && f.runtime.ledger?.record(id: "d_150") != nil)
        let reload = try DeliveryLedger(location: f.directory.appendingPathComponent("deliveries.json"))
        #expect(reload.records == f.runtime.ledger?.records)
    }

    @Test func synchronousAnswerDedupMemoryIsBoundedAndImmediateDuplicateRemainsSuppressed() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.cards.onAdd = { f.cards.respond(id: $0.id, text: "Yes") }
        for _ in 0..<510 { _ = await f.call("zeus_ask", ["text": "Answer now"]) }
        #expect(f.runtime.completedResponseIDs.count == 500 && f.runtime.handledResponses.count == 500)
        let card = try #require(f.cards.values.last)
        f.runtime.receivedResponse(card, response: try #require(card.response))
        #expect(f.runtime.ledger?.records.isEmpty == true)
    }
}
