import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

extension ZeusE2ETests {
    @Test func peekOptionProducesOneChannelDeliveryToItsOrigin() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let conversation = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        let peek = f.installPeek(conversation: conversation)
        let origin = try await f.bridge("origin"), assistant = try await f.bridge()
        f.routing.assistantSessionKey = f.key()
        let pending = try await origin.call("zeus_ask", ["text": "Ship this build?", "wait_seconds": 0,
            "priority": "high", "options": [["id": "ship", "label": "Ship it"], ["id": "hold", "label": "Hold"]]])
        let cardID = try e2eString(pending["card_id"])
        #expect(peek.card?.id == cardID && peek.isVisible && peek.types)
        #expect(f.cards.unseenCount == 1 && !conversation.isPanelOpen)
        peek.setHovering(true)
        #expect(peek.answer(optionID: "ship"))
        #expect(!peek.answer(optionID: "hold"))
        #expect(!conversation.pickOption(cardID: cardID, optionID: "hold"))
        #expect(peek.answeredOptionID == "ship" && peek.isVisible && !peek.isTyping)
        #expect(f.cards.unseenCount == 0 && !conversation.isPanelOpen)
        let saved = CardStore(fileURL: f.directory.appendingPathComponent("cards.json"), clock: { f.clock.now })
        #expect(saved.card(id: cardID)?.response?.optionID == "ship")
        #expect(saved.card(id: cardID)?.response?.device == .mac)
        let push = try await origin.channel(cardID: cardID)
        let deliveryID = try e2eString(push["meta"]?["delivery_id"])
        #expect(push["content"] == "Reply to \"Ship this build?\": Ship it")
        #expect(push["meta"] == ["kind": "reply", "delivery_id": .string(deliveryID),
            "card_id": .string(cardID), "option_id": "ship"])
        try await eventually { f.runtime.sends.isEmpty }
        #expect(f.runtime.ledger?.records.count == 1)
        #expect(f.runtime.ledger?.record(id: deliveryID)?.delivery.sessionKey == f.key("origin"))
        #expect(f.runtime.ledger?.record(id: deliveryID)?.delivery.attempts == 1)
        _ = try await origin.call("zeus_ack", ["delivery_ids": [.string(deliveryID)]])
        f.clock.advance(0.6); peek.tick(suppression: .init())
        #expect(!peek.isVisible) // Receipt expires even while hovered and high priority.
        f.clock.advance(120); f.runtime.processDueDeliveries()
        try await origin.finish(); try await assistant.finish() // Drain stdout through EOF before counting duplicates.
        #expect(origin.channels.isEmpty && assistant.channels.isEmpty)
        #expect(f.runtime.ledger?.records.count == 1)
    }

    @Test func failedPeekAnswerSaveProducesNoDeliveryUntilRetrySucceeds() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let conversation = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        let peek = f.installPeek(conversation: conversation)
        let bridge = try await f.bridge()
        let pending = try await bridge.call("zeus_ask", ["text": "Keep the draft?", "wait_seconds": 0,
            "options": [["id": "keep", "label": "Keep"]]])
        let cardID = try e2eString(pending["card_id"])
        let cardsURL = f.directory.appendingPathComponent("cards.json")
        try FileManager.default.removeItem(at: cardsURL)
        try FileManager.default.createDirectory(at: cardsURL, withIntermediateDirectories: false)
        #expect(!peek.answer(optionID: "keep"))
        #expect(peek.answerError?.contains("Could not save your reply") == true)
        #expect(peek.isVisible && peek.answeredOptionID == nil)
        #expect(f.cards.card(id: cardID)?.status == .open && f.cards.card(id: cardID)?.response == nil)
        #expect(!f.cards.seenIDs.contains(cardID))
        _ = try await bridge.rpc("ping")
        #expect(f.runtime.ledger?.records.isEmpty == true && f.runtime.sends.isEmpty && bridge.channels.isEmpty)
        try FileManager.default.removeItem(at: cardsURL)
        #expect(peek.answer(optionID: "keep"))
        #expect(peek.answerError == nil)
        #expect(CardStore(fileURL: cardsURL, clock: { f.clock.now }).card(id: cardID)?.status == .answered)
        let push = try await bridge.channel(cardID: cardID)
        #expect(push["content"] == "Reply to \"Keep the draft?\": Keep")
        let deliveryID = try e2eString(push["meta"]?["delivery_id"])
        try await eventually { f.runtime.sends.isEmpty }
        #expect(f.runtime.ledger?.records.count == 1 && f.runtime.ledger?.record(id: deliveryID)?.delivery.attempts == 1)
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [.string(deliveryID)]])
        f.clock.advance(120); f.runtime.processDueDeliveries()
        try await bridge.finish()
        #expect(bridge.channels.isEmpty)
    }

    @Test func realArrivalsRevealOnceAcrossPeekPanelUpdatesAndRuntimeRestart() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let conversation = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        let peek = f.installPeek(conversation: conversation)
        let bridge = try await f.bridge()
        let said = try await bridge.call("zeus_say", ["text": "**First** arrival ⚡"])
        let peekID = try e2eString(said["card_id"])
        let startedAt = peek.startedAt
        #expect(peek.types && f.cards.revealedIDs.contains(peekID) && f.cards.unseenCount == 1)
        f.clock.advance(0.1)
        _ = try await bridge.call("zeus_update_card", ["card_id": .string(peekID), "append_text": " Updated."])
        #expect(peek.startedAt == startedAt && peek.card?.id == peekID)
        f.clock.advance(30); peek.tick(suppression: .init())
        #expect(!peek.isVisible && f.cards.unseenCount == 1) // Auto-hide never marks read.
        conversation.openPanel(viewportManaged: true); peek.panelOpened()
        let updated = try #require(f.cards.card(id: peekID))
        conversation.noteArrival(updated, visible: true, animate: true)
        #expect(conversation.revealer(cardID: peekID) == nil)
        let longText = String(repeating: "👨‍👩‍👧‍👦", count: 600)
        let visible = try await bridge.call("zeus_say", ["text": .string(longText)])
        let panelID = try e2eString(visible["card_id"])
        let reveal = try #require(conversation.revealer(cardID: panelID))
        #expect(reveal.isRevealing && !peek.isVisible)
        #expect(reveal.text.count == 600)
        reveal.markDisplayed()
        f.clock.advance(2.5); reveal.tick() // Sample after the cap, independent of Date's fractional rounding.
        #expect(reveal.visibleCount == 600)
        #expect(!reveal.isRevealing)
        conversation.closePanel(); conversation.openPanel(viewportManaged: true)
        conversation.noteArrival(try #require(f.cards.card(id: panelID)), visible: true, animate: true)
        #expect(conversation.revealer(cardID: panelID) === reveal && !reveal.isRevealing)
        try f.restart()
        let restored = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        let restoredPeek = f.installPeek(conversation: restored)
        #expect(f.cards.revealedIDs == [peekID, panelID] && f.cards.unseenCount == 2)
        #expect(!restoredPeek.isVisible)
        restored.openPanel(viewportManaged: true)
        for card in f.cards.cards {
            restored.noteArrival(card, visible: true, animate: true)
            #expect(restored.revealer(cardID: card.id) == nil)
        }
        try await eventually { f.runtime.sessions.count == 1 }
        _ = try await bridge.call("zeus_update_card", ["card_id": .string(panelID), "append_text": " Full text after restart."])
        #expect(restored.revealer(cardID: panelID) == nil && !restoredPeek.isVisible)
        #expect(f.runtime.ledger?.records.isEmpty == true)
        try await bridge.finish()
        #expect(bridge.channels.isEmpty)
    }

    @Test func peekReplyRearmsTextQuestionAndLateAnswerKeepsItsCaptionAndRouting() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let conversation = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        let peek = f.installPeek(conversation: conversation)
        let bridge = try await f.bridge()
        let pending = try await bridge.call("zeus_ask", ["title": "Review the outline", "text": "What should change?",
            "allow_text": true, "wait_seconds": 0])
        let cardID = try e2eString(pending["card_id"])
        conversation.clearReplyTarget()
        #expect(conversation.replyTarget == nil)
        let expansion = try #require(peek.expand(.reply))
        #expect(expansion == PeekModel.Expansion(cardID: cardID, reply: true))
        conversation.rearmReplyTarget(cardID: expansion.cardID)
        conversation.openPanel(viewportManaged: true); peek.panelOpened()
        f.clock.advance(1)
        let optionsOnly = try await bridge.call("zeus_ask", ["text": "Also ship the build?", "wait_seconds": 0,
            "allow_text": false, "options": [["id": "ship", "label": "Ship"]]])
        let optionsID = try e2eString(optionsOnly["card_id"])
        f.clock.advance(1)
        let later = try await bridge.call("zeus_say", ["text": "New context arrived while you were replying."])
        let laterID = try e2eString(later["card_id"])
        #expect(!peek.isVisible && conversation.replyTarget?.id == cardID && conversation.shortcutTarget?.id == optionsID)
        f.clock.advance(1)
        conversation.draft = "Expand the conclusion."
        #expect(await conversation.send() == .answered(cardID: cardID))
        #expect(conversation.draft.isEmpty && f.cards.card(id: optionsID)?.status == .open)
        let thread = conversation.thread
        let answer = try #require(thread.last)
        let previous = try #require(thread.dropLast().last)
        #expect(answer.sourceCardID == cardID && answer.body == "Expand the conclusion.")
        #expect(previous.sourceCardID == laterID)
        #expect(ConversationLayout.answerCaption(answer, after: previous, cards: f.cards.cards) == "Review the outline")
        #expect(!f.cards.cards.contains { $0.kind == .userMessage })
        let push = try await bridge.channel(cardID: cardID)
        #expect(push["content"] == "Reply to \"Review the outline\": Expand the conclusion.")
        #expect(push["meta"]?["kind"] == "reply" && push["meta"]?["option_id"] == nil)
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [try #require(push["meta"]?["delivery_id"])]])
        #expect(f.runtime.ledger?.records.count == 1)
        try f.restart()
        let restored = ConversationModel(cards: f.cards, messaging: f.runtime, clock: { f.clock.now })
        let restoredThread = restored.thread
        #expect(restoredThread == thread)
        #expect(ConversationLayout.answerCaption(try #require(restoredThread.last), after: restoredThread.dropLast().last,
            cards: f.cards.cards) == "Review the outline")
        try await eventually { f.runtime.sessions.count == 1 }
        #expect(e2eIsEmptyPoll(try await bridge.call("zeus_get_responses"), mode: "channel", push: true))
        try await bridge.finish()
        #expect(bridge.channels.isEmpty)
    }
}

private extension E2EFixture {
    /// Mirrors ShellController's headless arrival decisions using the real UI models.
    /// Panel focus, placement, rendering and the actual button wiring remain visual QA.
    func installPeek(conversation: ConversationModel) -> PeekModel {
        let peek = PeekModel(store: cards, clock: { [clock] in clock.now })
        cards.onAdd = { [weak peek, weak conversation, weak status] card in
            guard let peek, let conversation, let status else { return }
            if peek.receive(card, suppression: .init(panelOpen: conversation.isPanelOpen), reduceMotion: false, typewriter: true) {
                status.notePeek(card, reduceMotion: false, typewriter: peek.types)
            } else {
                conversation.noteArrival(card, visible: conversation.isPanelOpen, animate: true)
                if !peek.isVisible { status.noteNewCard(card) }
            }
        }
        return peek
    }
}
