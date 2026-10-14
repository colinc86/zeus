import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct RuntimeToolTests {
    @Test func messagesContentUpdatesDismissalStatusAndCharacters() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let say = await f.call("zeus_say", ["text": "Hello", "title": "Update", "mood": "happy", "priority": "high", "ttl_seconds": 30,
                                         "attachments": [["kind": "file", "label": "Draft", "target": "~/draft.key"]]])
        #expect(!say.isError && say.structured?["card_id"] != nil)
        let card = try #require(f.cards.values.first)
        #expect(card.kind == .message && card.body == "Hello" && card.title == "Update")
        #expect(card.mood == .happy && card.priority == .high && card.sessionKey == "claude:/assistant")
        #expect(card.expiresAt == f.clock.now.addingTimeInterval(30))
        #expect(card.attachments.first?.target == "~/draft.key")
        let update = await f.call("zeus_update_card", ["card_id": .string(card.id), "title": "New", "text": "First", "append_text": "\nSecond", "progress": 0.5])
        #expect(update.structured == ["ok": true, "title": "New", "progress": 0.5, "status": "open"])
        #expect(f.cards.card(id: card.id)?.body == "First\nSecond")
        #expect(f.cards.card(id: card.id)?.progress == 0.5)
        _ = await f.call("zeus_update_card", ["card_id": .string(card.id), "progress": nil])
        #expect(f.cards.card(id: card.id)?.progress == nil)
        #expect(await f.call("zeus_dismiss", ["card_id": .string(card.id)]).structured == ["ok": true])
        #expect(f.cards.card(id: card.id)?.status == .dismissed)
        #expect(await f.call("zeus_update_card", ["card_id": "missing", "text": "x"]).structured?["ok"] == false)
        let content = await f.call("zeus_present", ["title": "Work", "body": "**Done**", "actions": [["id": "revise", "label": "Revise", "style": "primary"]], "allow_text": true])
        #expect(content.structured?["card_id"] != nil)
        #expect(f.cards.values.last?.kind == .content && f.cards.values.last?.input != nil)
        #expect(f.cards.values.last?.options.first?.style == .primary)
        _ = await f.call("zeus_set_status", ["state": "working", "detail": "Drafting", "progress": 0.5])
        #expect(f.status.state == .working && f.status.detail == "Drafting" && f.status.progress == 0.5 && f.status.ttl == 600)
        _ = await f.call("zeus_set_status", ["state": "auto"])
        #expect(f.status.state == nil)
        let list = await f.call("zeus_list_characters")
        #expect(list.structured?["current"] == "zeus")
        #expect(list.structured?["characters"]?[0]?["id"] == "zeus")
        #expect(await f.call("zeus_set_character", ["id": "zeus"]).structured == ["ok": true, "previous": "zeus", "current": "zeus"])
        #expect(await f.call("zeus_set_character", ["id": "missing"]).isError)
        #expect(try JSONValue.from(say).decode(ToolResult.self) == say)
        #expect(try ZeusJSON.decoder().decode(JSONValue.self, from: Data(say.text.utf8)) == say.structured)
    }

    @Test func invalidArgumentsDoNotMutateTheUI() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        for (name, args): (String, JSONValue) in [
            ("zeus_say", [:]), ("zeus_say", ["text": true]), ("zeus_say", ["text": "x", "ttl_seconds": -1]),
            ("zeus_present", ["title": "x"]), ("zeus_set_status", ["state": "wrong"]),
            ("zeus_set_status", ["state": "working", "progress": 2]),
            ("zeus_ask", ["text": "x", "options": [["id": "same", "label": "A"], ["id": "same", "label": "B"]]]),
            ("zeus_ack", [:]), ("zeus_ack", ["delivery_ids": [1]]), ("missing_tool", [:]),
            ("zeus_say", ["text": "x", "unexpected": true])
        ] {
            let result = await f.call(name, args)
            #expect(result.isError)
            #expect(result.structured?["error"] != nil)
        }
        #expect(f.cards.values.isEmpty && f.status.state == nil)
    }

    @Test func askAnsweredWithinWindowProducesNoLedgerRecord() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let task = Task { await f.call("zeus_ask", ["text": "Started?", "options": [["id": "no", "label": "No"]]]) }
        try await eventually { f.cards.values.count == 1 }
        let card = try #require(f.cards.values.first)
        #expect(card.input == nil)
        f.clock.advance(44)
        f.cards.respond(id: card.id, option: "no", label: "No", text: "Not yet", device: .ios)
        let answered = await task.value
        #expect(answered.structured == ["status": "answered", "card_id": .string(card.id), "option_id": "no", "option_label": "No", "text": "Not yet"])
        #expect(f.runtime.ledger?.records.isEmpty == true && f.connector.deliveries.isEmpty)
        // Defensive duplicate callback cannot turn a synchronous answer into a late delivery.
        let response = try #require(f.cards.card(id: card.id)?.response)
        f.runtime.receivedResponse(card, response: response)
        #expect(f.runtime.ledger?.records.isEmpty == true)
    }

    @Test func answerAtDeadlineUsesExactlyOnePendingPath() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let task = Task { await f.call("zeus_ask", ["text": "Started?", "wait_seconds": 45]) }
        try await eventually { f.cards.values.count == 1 }
        let card = try #require(f.cards.values.first)
        #expect(card.input?.multiline == false)
        // Move time without waking the timeout task: response callback wins scheduling,
        // but the elapsed deadline still sends the answer down the delivery path.
        f.clock.advance(45, wake: false)
        f.cards.respond(id: card.id, text: "Late")
        #expect(await task.value.structured == ["status": "pending", "card_id": .string(card.id)])
        #expect(f.runtime.ledger?.records.count == 1)
        #expect(f.runtime.ledger?.records.first?.response?.text == "Late")
    }

    @Test func timeoutThenAnswerQueuesAndClampsWaitWindows() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let task = Task { await f.call("zeus_ask", ["text": "Long wait", "wait_seconds": 9999, "placeholder": "Type", "multiline": true]) }
        try await eventually { f.cards.values.count == 1 }
        let card = try #require(f.cards.values.first)
        #expect(f.runtime.waiters[card.id]?.deadline == f.clock.now.addingTimeInterval(600))
        #expect(card.input == InputSpec(placeholder: "Type", multiline: true))
        f.clock.advance(600)
        #expect(await task.value.structured?["status"] == "pending")
        f.cards.respond(id: card.id, text: "Answer")
        #expect(f.runtime.ledger?.records.count == 1)
        #expect(f.status.problem == nil)
        let immediate = await f.call("zeus_ask", ["text": "Immediate", "wait_seconds": -10])
        #expect(immediate.structured?["status"] == "pending")
    }

    @Test func immediateStoreAnswerAndAskCancellationResolveOnce() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.cards.onAdd = { card in f.cards.respond(id: card.id, text: "Immediate") }
        #expect(await f.call("zeus_ask", ["text": "Question"]).structured?["status"] == "answered")
        #expect(f.runtime.ledger?.records.isEmpty == true)
        f.cards.onAdd = nil
        let task = Task { await f.call("zeus_ask", ["text": "Cancel"]) }
        try await eventually { f.cards.values.count == 2 }
        task.cancel()
        #expect(await task.value.structured?["status"] == "pending")
        let card = try #require(f.cards.values.last)
        f.cards.respond(id: card.id, text: "After cancellation")
        #expect(f.runtime.ledger?.records.count == 1)
    }
}
