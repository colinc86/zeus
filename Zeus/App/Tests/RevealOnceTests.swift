import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class RevealFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-reveal-once-\(UUID())")
    let clock = TestClock()
    let store: CardStore
    let conversation: ConversationModel
    init() {
        let clock = clock
        store = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        conversation = ConversationModel(cards: store, messaging: AgentMessagingHub(), clock: { clock.now })
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor struct RevealOnceTests {
    @Test func visibleArrivalRevealsOnceAndScrollRecreationUsesTheSameFinishedModel() throws {
        let f = RevealFixture(); defer { f.cleanup() }
        f.conversation.openPanel(viewportManaged: true)
        let card = Card(kind: .message, body: "**New message** with text")
        f.store.add(card)
        f.conversation.noteArrival(card, visible: true, animate: true)
        let reveal = try #require(f.conversation.revealer(cardID: card.id))
        #expect(reveal.text == "New message with text")
        #expect(reveal.isRevealing)
        #expect(f.store.revealedIDs == [card.id])
        #expect(f.store.unseenCount == 1) // Revealed isn't the same as read.
        reveal.markDisplayed()
        f.clock.advance(0.1); reveal.tick()
        #expect(reveal.visibleCount == 4)
        reveal.finish() // Row exits the viewport; its replacement uses this same model.
        #expect(f.conversation.revealer(cardID: card.id) === reveal)
        f.conversation.noteArrival(card, visible: true, animate: true)
        #expect(f.conversation.revealer(cardID: card.id) === reveal)
        #expect(!reveal.isRevealing)
        f.conversation.closePanel(); f.conversation.openPanel(viewportManaged: true)
        #expect(!reveal.isRevealing)
        let restored = CardStore(fileURL: f.root.appendingPathComponent("cards.json"))
        let recreated = ConversationModel(cards: restored, messaging: AgentMessagingHub())
        recreated.noteArrival(card, visible: true, animate: true)
        #expect(recreated.revealer(cardID: card.id) == nil)
        #expect(restored.revealedIDs == [card.id])
    }

    @Test func peekConsumesRevealButNotSeenAndPanelNeverTypesItAgain() {
        let f = RevealFixture(); defer { f.cleanup() }
        let peek = PeekModel(store: f.store, clock: { f.clock.now })
        let card = Card(kind: .message, body: "Said in a peek")
        f.store.add(card)
        #expect(peek.receive(card, suppression: .init(), reduceMotion: false, typewriter: true))
        #expect(peek.types)
        #expect(f.store.revealedIDs.contains(card.id))
        #expect(f.store.unseenCount == 1)
        peek.close()
        f.conversation.openPanel(viewportManaged: true)
        f.conversation.noteArrival(card, visible: true, animate: true)
        #expect(f.conversation.revealer(cardID: card.id) == nil)
        #expect(f.store.unseenCount == 1)
        let restored = CardStore(fileURL: f.root.appendingPathComponent("cards.json"))
        #expect(restored.revealedIDs.contains(card.id))
    }

    @Test func suppressedOrOffscreenArrivalsAndLoadedHistoryNeverAnimateLater() {
        let f = RevealFixture(); defer { f.cleanup() }
        let card = Card(kind: .message, body: "While scrolled up")
        f.store.add(card)
        f.conversation.noteArrival(card, visible: false, animate: true)
        #expect(f.conversation.revealer(cardID: card.id) == nil)
        f.conversation.noteArrival(card, visible: true, animate: true)
        #expect(f.conversation.revealer(cardID: card.id) == nil)
        let history = Card(kind: .message, body: "Loaded history")
        f.store.add(history)
        f.conversation.openPanel(viewportManaged: true)
        f.conversation.noteArrival(history, visible: true, animate: true)
        #expect(f.conversation.revealer(cardID: history.id) == nil)
    }

    @Test func reducedMotionOrDisabledRevealIsStillConsumedForever() {
        let f = RevealFixture(); defer { f.cleanup() }
        let card = Card(kind: .message, body: "Static arrival")
        f.store.add(card)
        f.conversation.noteArrival(card, visible: true, animate: false)
        f.conversation.noteArrival(card, visible: true, animate: true)
        #expect(f.conversation.revealer(cardID: card.id) == nil)
        let peek = PeekModel(store: f.store, clock: { f.clock.now })
        let next = Card(kind: .message, body: "Reduce Motion")
        f.store.add(next)
        #expect(peek.receive(next, suppression: .init(), reduceMotion: true, typewriter: true))
        #expect(!peek.types)
        #expect(f.store.revealedIDs.contains(next.id))
    }

    @Test func legacySeenHistoryMigratesAndFailedRevealWritesCannotStartAnimation() throws {
        let f = RevealFixture(); defer { f.cleanup() }
        let card = Card(kind: .message, body: "Legacy seen")
        f.store.add(card); f.store.markSeen(id: card.id)
        let url = f.root.appendingPathComponent("cards.json")
        var snapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        snapshot.removeValue(forKey: "revealedIDs")
        try JSONSerialization.data(withJSONObject: snapshot).write(to: url)
        let restored = CardStore(fileURL: url)
        #expect(restored.revealedIDs == [card.id])
        let next = Card(kind: .message, body: "Cannot save reveal")
        f.store.add(next)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        f.conversation.noteArrival(next, visible: true, animate: true)
        #expect(f.conversation.revealer(cardID: next.id) == nil)
        #expect(!f.store.revealedIDs.contains(next.id))
        #expect(f.store.persistenceError != nil)
    }

    @Test func composerPreservesDraftAndOpenQuestionOnFailedAnswerWrite() async throws {
        let f = RevealFixture(); defer { f.cleanup() }
        let question = Card(kind: .question, body: "Reply?", input: InputSpec())
        f.store.add(question)
        let url = f.root.appendingPathComponent("cards.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        f.conversation.draft = "Keep this draft"
        let result = await f.conversation.send()
        guard case .rejected(let reason) = result else { Issue.record("Expected a retryable persistence failure"); return }
        #expect(reason.contains("Could not save"))
        #expect(f.conversation.draft == "Keep this draft")
        #expect(f.store.card(id: question.id)?.status == .open)
        #expect(f.store.card(id: question.id)?.response == nil)
    }
}
