import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Real subprocess/stdio → Unix socket → runtime/store → stdio channel round trips.
@MainActor
@Suite(.serialized)
struct ZeusE2ETests {
    @Test func eventDrivenStdinHandlesFragmentsAndEOFWithoutPolling() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let empty = try E2EBridge(socketPath: f.runtime.socketPath, cwd: f.directory)
        f.children.append(empty)
        try await empty.finish()
        #expect(f.runtime.sessions.isEmpty)
        let bridge = try await f.bridge()
        let result = try await bridge.fragmentedCall("zeus_say", ["text": "Ready for ⚡ input."])
        #expect(result["isError"] != true)
        #expect(f.cards.cards.last?.body == "Ready for ⚡ input.")
        try bridge.writeUnterminatedFrame()
        try await bridge.finish()
        #expect(bridge.inbox.contains { $0["error"]?["code"] == -32700 })
    }

    @Test func presentationScenario() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try await f.bridge()
        #expect(try await bridge.call("zeus_set_status", ["state": "thinking", "detail": "Preparing the presentation"]) == ["ok": true])
        #expect(f.status.presentation.state == .thinking)
        let pending = try await bridge.call("zeus_ask", ["text": "Have you started on the presentation?", "wait_seconds": 0,
            "options": [["id": "yes", "label": "Yes"], ["id": "no", "label": "No"]], "allow_text": true])
        #expect(pending["status"] == "pending")
        let cardID = try e2eString(pending["card_id"])
        try f.answer(cardID, text: "I haven't.", option: "no", label: "No")
        let push = try await bridge.channel(cardID: cardID)
        #expect(push["content"] == "Reply to \"Have you started on the presentation?\": No\nI haven't.")
        let id = try e2eString(push["meta"]?["delivery_id"])
        #expect(push["meta"] == ["kind": "reply", "delivery_id": .string(id), "card_id": .string(cardID), "option_id": "no"])
        try await eventually { f.runtime.sends.isEmpty }
        #expect(f.runtime.ledger?.record(id: id)?.delivery.ackedAt == nil) // stdout receipt isn't an ack.
        #expect(try await bridge.call("zeus_ack", ["delivery_ids": [.string(id)]]) == ["acked": [.string(id)]])
        #expect(try DeliveryLedger(location: f.runtime.ledgerURL).record(id: id)?.delivery.ackedAt != nil)
        let draft = f.directory.appendingPathComponent("presentation.md")
        try Data("# Presentation\nThe finished draft.\n".utf8).write(to: draft)
        let finished = try await bridge.call("zeus_present", ["title": "Presentation", "body": "The draft is ready.",
            "attachments": [["kind": "file", "label": "Open draft", "target": .string(draft.path)]],
            "actions": [["id": "good", "label": "Looks good"], ["id": "revise", "label": "Revise"]]])
        let card = try #require(f.cards.card(id: e2eString(finished["card_id"])))
        #expect(card.kind == .content && card.attachments.first?.target == draft.path && card.options.count == 2)
        #expect(f.cards.persistenceError == nil)
        #expect(CardStore(fileURL: f.directory.appendingPathComponent("cards.json")).cards.count == 2)
        _ = try await bridge.call("zeus_set_status", ["state": "auto"])
        try await bridge.finish()
    }

    enum AnswerOrder: String, CaseIterable { case beforeDeadline, responseAtDeadline, timerAtDeadline }
    @Test(arguments: AnswerOrder.allCases)
    func timeoutRaceHasExactlyOneAnswerPath(_ order: AnswerOrder) async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try await f.bridge()
        let callID = try bridge.send(method: "tools/call", params: ["name": "zeus_ask", "arguments": ["text": "Race", "wait_seconds": 1]])
        try await eventually { f.cards.cards.count == 1 && f.runtime.waiters.count == 1 }
        let cardID = try #require(f.cards.cards.first?.id)
        if order == .beforeDeadline { f.clock.advance(0.5, wake: false) }
        else { f.clock.advance(1, wake: order == .timerAtDeadline) }
        var early: JSONValue?
        if order == .timerAtDeadline { early = try await bridge.reply(to: callID) }
        try f.answer(cardID, text: "One answer")
        let result: JSONValue
        if let early { result = early } else { result = try await bridge.reply(to: callID) }
        let structured = try #require(result["structuredContent"])
        if order == .beforeDeadline {
            #expect(structured["status"] == "answered" && structured["text"] == "One answer")
            #expect(f.runtime.ledger?.records.isEmpty == true)
        } else {
            #expect(structured["status"] == "pending")
            let push = try await bridge.channel(cardID: cardID)
            #expect(push["content"] == "Reply to \"Race\": One answer")
            #expect(f.runtime.ledger?.records.count == 1)
            _ = try await bridge.call("zeus_ack", ["delivery_ids": [try #require(push["meta"]?["delivery_id"])]])
        }
        #expect(!f.cards.respond(id: cardID, response: .init(text: "Duplicate", respondedAt: f.clock.now, device: .mac)))
        _ = try await bridge.rpc("ping")
        #expect(bridge.channels.isEmpty && f.runtime.waiters.isEmpty)
        try await bridge.finish()
    }

    @Test func concurrentSessionsKeepRepliesAndAcknowledgmentsSeparate() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let a = try await f.bridge("a"), b = try await f.bridge("b")
        async let askedA = a.call("zeus_ask", ["text": "Question A", "wait_seconds": 0])
        async let askedB = b.call("zeus_ask", ["text": "Question B", "wait_seconds": 0])
        let (resultA, resultB) = try await (askedA, askedB)
        let cardA = try e2eString(resultA["card_id"]), cardB = try e2eString(resultB["card_id"])
        try f.answer(cardB, text: "Answer B"); try f.answer(cardA, text: "Answer A")
        let pushA = try await a.channel(cardID: cardA), pushB = try await b.channel(cardID: cardB)
        #expect(pushA["content"] == "Reply to \"Question A\": Answer A")
        #expect(pushB["content"] == "Reply to \"Question B\": Answer B")
        let idA = try #require(pushA["meta"]?["delivery_id"]), idB = try #require(pushB["meta"]?["delivery_id"])
        #expect(try await b.call("zeus_ack", ["delivery_ids": [idA]]) == ["acked": []])
        _ = try await a.call("zeus_ack", ["delivery_ids": [idA]])
        _ = try await b.call("zeus_ack", ["delivery_ids": [idB]])
        try await eventually { f.runtime.sends.isEmpty }
        #expect(a.channels.isEmpty && b.channels.isEmpty)
        #expect(f.runtime.ledger?.records.allSatisfy { $0.delivery.ackedAt != nil } == true)
        try await a.finish(); try await b.finish()
    }

    @Test func killedBridgeRebindsPendingQuestionToSameSessionKey() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let first = try await f.bridge()
        _ = try first.send(method: "tools/call", params: ["name": "zeus_ask", "arguments": ["text": "Still answerable", "wait_seconds": 600]])
        try await eventually { f.runtime.waiters.count == 1 }
        let cardID = try #require(f.cards.cards.first?.id)
        let firstBridgeID = try #require(f.runtime.sessions.first?.id)
        first.kill()
        try await eventually { f.runtime.sessions.isEmpty && f.runtime.waiters.isEmpty && !first.process.isRunning }
        try f.answer(cardID, text: "After the crash")
        let saved = try #require(f.runtime.ledger?.records.first?.delivery)
        #expect(saved.sessionKey == f.key() && saved.attempts == 0)
        let replacement = try await f.bridge()
        #expect(f.runtime.sessions.first?.id != firstBridgeID)
        let push = try await replacement.channel(cardID: cardID)
        #expect(push["meta"]?["delivery_id"] == .string(saved.id))
        #expect(push["content"] == "Reply to \"Still answerable\": After the crash")
        _ = try await replacement.call("zeus_ack", ["delivery_ids": [.string(saved.id)]])
        #expect(f.cards.card(id: cardID)?.status == .answered)
        try await replacement.finish()
    }

    @Test func newRuntimeReloadsPendingDeliveryAndExistingBridgeReconnects() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try await f.bridge()
        let question = try await bridge.call("zeus_ask", ["text": "Survive restart", "wait_seconds": 0])
        let cardID = try e2eString(question["card_id"])
        try f.answer(cardID)
        let firstPush = try await bridge.channel(cardID: cardID)
        try await eventually { f.runtime.sends.isEmpty }
        let savedID = try e2eString(firstPush["meta"]?["delivery_id"])
        let old = E2ERuntimeReference(f.runtime)
        try f.restart()
        try await eventually { old.value == nil }
        try await eventually { f.runtime.sessions.count == 1 }
        let replay = try await bridge.channel(cardID: cardID)
        #expect(replay["meta"]?["delivery_id"] == .string(savedID))
        #expect(f.cards.card(id: cardID)?.response?.text == "Yes")
        #expect(f.runtime.ledger?.record(id: savedID)?.delivery.attempts == 2)
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [.string(savedID)]])
        #expect(try DeliveryLedger(location: f.runtime.ledgerURL).record(id: savedID)?.delivery.ackedAt != nil)
        try await bridge.finish()
    }

    @Test func orphanedReplyReroutesThroughAssistantStdoutWithoutPermanentWarning() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let origin = try await f.bridge("one-shot")
        let pending = try await origin.call("zeus_ask", ["text": "Old question", "wait_seconds": 0])
        let cardID = try e2eString(pending["card_id"])
        origin.kill()
        try await eventually { f.runtime.sessions.isEmpty }
        try f.answer(cardID, text: "A late answer")
        f.clock.advance(121)
        try await eventually { f.runtime.deliveryIssue != nil }
        let assistant = try await f.bridge("assistant")
        let push = try await assistant.channel(cardID: cardID)
        #expect(push["content"] == "(Answer to a question from an earlier session) Reply to \"Old question\": A late answer")
        #expect(f.runtime.deliveryIssue == nil && f.status.deliveryProblem == nil)
        let id = try #require(push["meta"]?["delivery_id"])
        _ = try await assistant.call("zeus_ack", ["delivery_ids": [id]])
        f.clock.advance(10000)
        f.runtime.processDueDeliveries()
        #expect(f.runtime.deliveryIssue == nil && f.status.deliveryProblem == nil)
        #expect(assistant.channels.isEmpty)
        try await assistant.finish()
    }

    @Test func composerQueuesBeforeAnyAssistantAndPushesAfterRuntimeRestart() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let conversation = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        conversation.draft = "Saved before anyone connects"
        let result = await conversation.send()
        guard case .message(_, .queued) = result else { throw E2EFailure("Expected queued composer result") }
        #expect(conversation.draft.isEmpty)
        let initial = try #require(DeliveryLedger(location: f.runtime.ledgerURL).records.first)
        #expect(initial.awaitingAssistant == true && initial.delivery.attempts == 0)
        try f.restart()
        let bridge = try await f.bridge()
        let notification = try await bridge.userMessage()
        #expect(notification["content"] == "Message from the user: Saved before anyone connects")
        #expect(notification["meta"]?["delivery_id"] == .string(initial.delivery.id))
        let bound = try #require(f.runtime.ledger?.record(id: initial.delivery.id))
        #expect(bound.delivery.sessionKey == f.key() && bound.awaitingAssistant == nil)
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [.string(initial.delivery.id)]])
        try await bridge.finish()
    }

    @Test func unboundQueueWaitsForPreferredAgentAndCanBeConsumedByPolling() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        f.routing.preferredAgent = .codex; f.routing.deliveryMethod = .polling
        #expect(await f.runtime.sendUserMessage("For Codex") == .queued(reason: "Waiting for your assistant to connect."))
        let claude = try await f.bridge("unrelated")
        #expect(e2eIsEmptyPoll(try await claude.call("zeus_get_responses"), mode: "polling", push: false))
        #expect(f.runtime.ledger?.records.first?.awaitingAssistant == true)
        let codex = try await f.bridge("assistant", agent: .codex)
        let items = try await codex.call("zeus_get_responses")
        #expect(items["items"]?[0]?["text"] == "For Codex")
        #expect(f.runtime.ledger?.records.first?.delivery.sessionKey == f.key(agent: .codex))
        #expect(f.runtime.ledger?.records.first?.delivery.ackedAt != nil)
        #expect(f.runtime.ledger?.records.first?.delivery.attempts == 0)
        #expect(claude.channels.isEmpty && codex.channels.isEmpty)
        try await claude.finish(); try await codex.finish()
    }

    @Test func pollingOnlyReturnsAndAcksAnswersAndComposeMessages() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let bridge = try await f.bridge(agent: .codex)
        let pending = try await bridge.call("zeus_ask", ["text": "Pull-only", "wait_seconds": 0])
        let cardID = try e2eString(pending["card_id"])
        try f.answer(cardID, text: "Polled answer")
        let conversation = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        _ = await conversation.send("A plain user message")
        let result = try await bridge.call("zeus_get_responses")
        guard case .array(let items) = result["items"] else { throw E2EFailure("Missing polling items") }
        #expect(items.count == 2)
        #expect(items[0]["card_id"] == .string(cardID) && items[0]["text"] == "Polled answer")
        #expect(items[1]["kind"] == "userMessage" && items[1]["text"] == "A plain user message")
        #expect(f.cards.cards.contains { $0.kind == .userMessage && $0.body == "A plain user message" })
        #expect(f.runtime.ledger?.records.allSatisfy { $0.delivery.ackedAt != nil && $0.delivery.attempts == 0 } == true)
        #expect(e2eIsEmptyPoll(try await bridge.call("zeus_get_responses"), mode: "polling", push: false))
        #expect(bridge.channels.isEmpty && f.status.deliveryProblem == nil)
        try await bridge.finish()
    }
}
