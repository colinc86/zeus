import Foundation
import Testing
import ZeusDesign
import ZeusProtocol
import ZeusSprites
@testable import Zeus

@MainActor private final class PeekFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-peek-\(UUID())")
    let clock = TestClock()
    let store: CardStore
    let model: PeekModel
    init() {
        let clock = clock
        store = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        model = PeekModel(store: store, clock: { clock.now })
    }
    func add(_ card: Card, suppression: PeekModel.Suppression = .init(), reduceMotion: Bool = false, typewriter: Bool = true) -> Bool {
        store.add(card)
        return model.receive(card, suppression: suppression, reduceMotion: reduceMotion, typewriter: typewriter)
    }
    func tick(_ seconds: TimeInterval, suppression: PeekModel.Suppression = .init()) { clock.advance(seconds); model.tick(suppression: suppression) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor struct PeekModelTests {
    @Test func closedSuppressedArrivalStateStaysBoundedByHistoryAndMoreKeepsItsOrder() {
        let f = PeekFixture(); defer { f.cleanup() }
        f.store.onHistoryCleared = { f.model.pruneRetainedHistory() }
        let question = Card(kind: .question, body: "Protected old question", input: .init())
        #expect(!f.add(question, suppression: .init(hidden: true)))
        for index in 0..<1100 {
            f.clock.advance(1)
            let card = Card(id: "closed-arrival-\(index)", kind: .message, body: "Suppressed message", createdAt: f.clock.now, updatedAt: f.clock.now)
            #expect(!f.add(card, suppression: .init(hidden: true)))
            f.store.dismiss(id: card.id)
            f.store.retainHistory(keepingNewest: 500, pendingCardIDs: [])
        }
        #expect(f.store.cards.count == 501 && f.model.arrivals.count == 501)
        #expect(Set(f.model.arrivals) == Set(f.store.cards.map(\.id)))
        // Dismissed arrivals stay in history and in arrival order, but never count toward "+N more" (FX16).
        #expect(f.model.moreCount == 1 && f.model.oldestUnseenID == question.id)
        #expect(f.model.arrivals.first == question.id && f.model.arrivals.last == "closed-arrival-1099" && f.model.arrivals[1] == "closed-arrival-600")
        f.store.markSeen(id: question.id)
        #expect(f.model.moreCount == 0 && f.model.oldestUnseenID == nil)
        #expect(!f.model.receive(question, suppression: .init(), reduceMotion: false, typewriter: true))
        #expect(f.store.clearConversation())
        #expect(f.model.arrivals == [question.id] && f.model.moreCount == 0)
        f.model.panelOpened()
        #expect(f.model.arrivals.isEmpty)
    }

    @Test func shellHistoryCallbackPrunesPeekStateAndPreservesAVisibleRevealedQuestion() throws {
        let suite = "zeus-peek-prune-shell-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let f = PeekFixture(); defer { f.cleanup() }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let shell = ShellController(defaults: defaults, cards: f.store, settings: settings)
        // Exercise its installed history hook without ordering any native panels or announcing arrivals.
        f.store.onAdd = nil
        let done = Card(kind: .message, body: "Remove this history", status: .dismissed)
        f.store.add(done)
        let question = Card(kind: .question, body: "Still open", input: .init())
        f.store.add(question)
        #expect(shell.peek.receive(question, suppression: .init(), reduceMotion: false, typewriter: true))
        #expect(shell.peek.isVisible && shell.peek.card?.id == question.id)
        #expect(f.store.revealedIDs.contains(question.id))
        #expect(f.store.clearConversation())
        #expect(shell.peek.arrivals == [question.id] && shell.peek.isVisible)
        #expect(!shell.peek.receive(question, suppression: .init(), reduceMotion: false, typewriter: true))
        #expect(f.store.revealedIDs.contains(question.id))
    }

    @Test func terminalActionKeepsPeekOpenWithoutAnAnswerReceipt() throws {
        let f = PeekFixture(); defer { f.cleanup() }
        let card = Card(kind: .content, body: "Answer it in Terminal.",
                        options: [.init(id: "open-terminal", label: "Open in Terminal", style: .primary)], priority: .high)
        var opened = 0
        f.store.localActionHandler = { _, response in
            guard response.optionID == "open-terminal" else { return false }
            opened += 1
            return true
        }
        var replies = 0
        f.store.responseHandler = { _, _ in replies += 1 }
        #expect(f.add(card, typewriter: false))
        #expect(f.model.answer(optionID: "open-terminal"))
        #expect(f.model.isVisible && f.model.answeredOptionID == nil && f.model.answerError == nil)
        f.tick(1)
        #expect(f.model.isVisible && f.store.card(id: card.id)?.response == nil)
        #expect(f.model.answer(optionID: "open-terminal") && opened == 2 && replies == 0)
        #expect(CardStore(fileURL: f.root.appendingPathComponent("cards.json")).card(id: card.id)?.status == .open)
    }
    @Test func onlyNewOpenAgentMessageQuestionContentArrivalsPeek() {
        let f = PeekFixture(); defer { f.cleanup() }
        for kind in Card.Kind.allCases {
            let eligible = [.message, .question, .content].contains(kind)
            let card = Card(kind: kind, body: "Hello")
            #expect(f.add(card) == eligible)
            f.model.close()
        }
        #expect(!f.add(Card(kind: .message, body: "Expired", status: .expired)))
        let card = Card(kind: .message, body: "First")
        #expect(f.add(card))
        f.model.close()
        #expect(!f.model.receive(card, suppression: .init(), reduceMotion: false, typewriter: true))
        f.store.update(id: card.id) { $0.body = "Updated" }
        #expect(!f.model.isVisible)
    }

    @Test func visiblePeekUsesUpdatedBodyTitleAndOptionsWithoutReplayingOrExtendingDeadline() throws {
        let f = PeekFixture(); defer { f.cleanup() }
        let card = Card(kind: .message, title: "Old title", body: "Old instruction")
        #expect(f.add(card, typewriter: false))
        let deadline = f.model.nextDeadline
        let started = f.model.startedAt
        #expect(f.store.update(id: card.id) { $0.body = "Corrected instruction"; $0.title = "New title" })
        #expect(f.model.card?.body == "Corrected instruction" && f.model.card?.title == "New title")
        #expect(f.store.update(id: card.id) { $0.body += " plus an appendix"; $0.options = [.init(id: "new", label: "New")] })
        #expect(f.model.card?.body == "Corrected instruction plus an appendix")
        #expect(f.model.card?.options.first?.id == "new")
        f.model.tick(suppression: .init())
        #expect(f.model.nextDeadline == deadline && f.model.startedAt == started)
        #expect(f.store.revealedIDs == [card.id])
        #expect(!f.model.receive(try #require(f.model.card), suppression: .init(), reduceMotion: false, typewriter: true))
        f.store.dismiss(id: card.id); f.model.tick(suppression: .init())
        #expect(!f.model.isVisible)
    }

    @Test func updateDuringTypingKeepsOriginalAttentionBudgetAndHighPeekStaysLive() {
        let f = PeekFixture(); defer { f.cleanup() }
        let card = Card(kind: .message, body: "Hi", priority: .high)
        #expect(f.add(card))
        let end = f.model.nextDeadline
        f.store.update(id: card.id) { $0.body = String(repeating: "Long correction ", count: 100) }
        #expect(f.model.nextDeadline == end)
        f.tick(1)
        #expect(!f.model.isTyping && f.model.isVisible)
        #expect(f.model.card?.body == f.store.card(id: card.id)?.body)
        f.tick(1000)
        #expect(f.model.isVisible)
    }

    @Test func suppressionNeverReplaysAndDoesNotMarkUnseenCards() {
        let f = PeekFixture(); defer { f.cleanup() }
        for suppression in [PeekModel.Suppression(panelOpen: true), .init(hidden: true), .init(quiet: true), .init(focused: true)] {
            #expect(!f.add(Card(kind: .message, body: "Suppressed"), suppression: suppression))
            f.model.tick(suppression: .init())
            #expect(!f.model.isVisible)
        }
        #expect(f.store.unseenCount == 4)
        #expect(f.add(Card(kind: .message, body: "Unknown Focus"), suppression: .init(focused: nil)))
        f.model.tick(suppression: .init(quiet: true))
        #expect(!f.model.isVisible)
        #expect(f.store.unseenCount == 5)
    }

    @Test func replacementShowsNewestCountsOtherUnseenAndOpeningResetsArrivalWindow() throws {
        let f = PeekFixture(); defer { f.cleanup() }
        let old = Card(kind: .message, body: "Old history")
        f.store.add(old) // Existing history is outside this peek's arrival window.
        let first = Card(kind: .message, body: "First"), second = Card(kind: .question, body: "Second", input: InputSpec())
        #expect(f.add(first)); f.clock.advance(1)
        #expect(f.add(second))
        #expect(f.model.card?.id == second.id)
        #expect(f.model.startedAt == f.clock.now)
        #expect(f.model.moreCount == 1)
        #expect(f.model.oldestUnseenID == first.id)
        #expect(f.store.unseenCount == 3)
        let expansion = try #require(f.model.expand(.more))
        #expect(expansion == .init(cardID: first.id, reply: false))
        #expect(f.store.unseenCount == 3)
        f.model.panelOpened()
        #expect(f.model.moreCount == 0)
        #expect(f.add(Card(kind: .message, body: "New window")))
        #expect(f.model.moreCount == 0)
    }

    @Test func readingTimerStartsAfterTypingAndTimeoutLeavesCardUnseen() {
        let f = PeekFixture(); defer { f.cleanup() }
        let card = Card(kind: .message, body: String(repeating: "a", count: 100))
        #expect(f.add(card))
        #expect(f.model.isTyping)
        f.tick(8.399)
        #expect(!f.model.isTyping)
        #expect(f.model.isVisible)
        f.tick(0.001)
        #expect(!f.model.isVisible)
        #expect(f.store.unseenCount == 1)
    }

    @Test func hoverPausesResumesWithMinimumAndReplacementRestartsPause() {
        let f = PeekFixture(); defer { f.cleanup() }
        #expect(f.add(Card(kind: .message, body: "Hi"), reduceMotion: true))
        f.tick(5)
        f.model.setHovering(true)
        f.tick(100)
        #expect(f.model.isVisible)
        f.model.setHovering(false)
        f.tick(1.999)
        #expect(f.model.isVisible)
        f.tick(0.001)
        #expect(!f.model.isVisible)
        #expect(f.add(Card(kind: .message, body: "Again"), typewriter: false))
        f.model.setHovering(true)
        #expect(f.add(Card(kind: .message, body: "Replaced"), reduceMotion: true))
        f.tick(100)
        #expect(f.model.isVisible)
        f.model.setHovering(false)
        f.tick(5.999)
        #expect(f.model.isVisible)
        f.tick(0.001)
        #expect(!f.model.isVisible)
    }

    @Test func hoveringBeforeTypingEndsPreservesOnlyTheReadingTime() {
        let f = PeekFixture(); defer { f.cleanup() }
        #expect(f.add(Card(kind: .message, body: String(repeating: "a", count: 100))))
        f.tick(1); f.model.setHovering(true)
        f.tick(1); f.model.setHovering(false)
        f.tick(6.399)
        #expect(f.model.isVisible)
        f.tick(0.001)
        #expect(!f.model.isVisible)
    }

    @Test func highPriorityStaysUntilInteractionAndCloseMarksOnlyShownCard() {
        let f = PeekFixture(); defer { f.cleanup() }
        let first = Card(kind: .message, body: "First")
        let high = Card(kind: .message, body: "High", priority: .high)
        #expect(f.add(first)); #expect(f.add(high))
        f.tick(1000)
        #expect(f.model.isVisible)
        f.model.setHovering(true); f.tick(1000); f.model.setHovering(false); f.tick(1000)
        #expect(f.model.isVisible)
        f.model.close(markSeen: true)
        #expect(f.store.seenIDs == [high.id])
        #expect(f.store.unseenCount == 1)
    }

    @Test func optionAnswersOnceWithoutExpansionThenHidesAfterReceiptDespiteHover() {
        let f = PeekFixture(); defer { f.cleanup() }
        let card = Card(kind: .question, body: "Ready?", options: [CardOption(id: "yes", label: "Yes")], priority: .high)
        var calls = 0
        f.store.responseHandler = { _, _ in calls += 1 }
        #expect(f.add(card))
        f.model.setHovering(true)
        #expect(f.model.answer(optionID: "yes"))
        #expect(f.model.answeredOptionID == "yes")
        #expect(!f.model.answer(optionID: "yes"))
        #expect(!f.store.isConversationOpen)
        #expect(f.store.seenIDs == [card.id])
        f.tick(0.599)
        #expect(f.model.isVisible)
        f.tick(0.001)
        #expect(!f.model.isVisible)
        #expect(calls == 1)
    }

    @Test func failedOptionPersistenceKeepsBubbleAndQuestionRetryable() throws {
        let f = PeekFixture(); defer { f.cleanup() }
        let card = Card(kind: .question, body: "Ready?", options: [CardOption(id: "yes", label: "Yes")])
        #expect(f.add(card))
        let url = f.root.appendingPathComponent("cards.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(!f.model.answer(optionID: "yes"))
        #expect(f.model.answerError?.contains("Could not save") == true)
        #expect(f.model.answeredOptionID == nil)
        #expect(f.model.isVisible)
        #expect(f.store.card(id: card.id)?.status == .open)
        #expect(f.store.unseenCount == 1)
        try FileManager.default.removeItem(at: url)
        #expect(f.model.answer(optionID: "yes"))
        #expect(f.model.answerError == nil)
    }

    @Test func bodyReplyAndPanelOpeningHideAndMarkSeenAccordingToAction() {
        let f = PeekFixture(); defer { f.cleanup() }
        let card = Card(kind: .question, body: "Text?", input: InputSpec())
        #expect(f.add(card))
        #expect(f.model.expand(.reply) == .init(cardID: card.id, reply: true))
        #expect(f.store.seenIDs.contains(card.id))
        #expect(!f.model.isVisible)
        let next = Card(kind: .message, body: "Next")
        #expect(f.add(next))
        f.model.panelOpened()
        #expect(!f.model.isVisible)
        #expect(!f.store.seenIDs.contains(next.id))
    }

    @Test func speechDurationMatchesTypingThenMoodAndReduceMotionIsOnePointTwoSeconds() {
        let f = PeekFixture(); defer { f.cleanup() }
        let status = AvatarStatusModel(cards: f.store, clock: { f.clock.now })
        let card = Card(kind: .message, body: "Twenty characters!!!", mood: .happy)
        let length = ZeusPeekTiming.typedLength(card.body)
        status.notePeek(card, reduceMotion: false)
        #expect(status.state == .talking)
        f.clock.advance(ZeusPeekTiming.talkingDuration(length: length, reduceMotion: false))
        status.tick(); #expect(status.state == .happy)
        f.clock.advance(2.5); status.tick(); #expect(status.state == .idle)
        status.notePeek(card, reduceMotion: true)
        f.clock.advance(1.199); status.tick(); #expect(status.state == .talking)
        f.clock.advance(0.001); status.tick(); #expect(status.state == .happy)
        status.stopPeekSpeech(cardID: card.id)
        #expect(status.state == .idle)
    }

    @Test func newestTextTargetSurvivesOptionsOnlyAndExplicitReplyRearmsClearedChip() {
        let f = PeekFixture(); defer { f.cleanup() }
        let model = ConversationModel(cards: f.store, messaging: AgentMessagingHub())
        let first = Card(kind: .question, body: "Text", input: InputSpec(), createdAt: f.clock.now)
        f.store.add(first)
        model.clearReplyTarget()
        f.clock.advance(1)
        f.store.add(Card(kind: .question, body: "Options", options: [CardOption(id: "yes", label: "Yes")], createdAt: f.clock.now))
        #expect(model.replyTarget == nil)
        model.rearmReplyTarget(cardID: first.id)
        #expect(model.replyTarget?.id == first.id)
        f.clock.advance(1)
        let newer = Card(kind: .question, body: "New text", input: InputSpec(), createdAt: f.clock.now)
        f.store.add(newer)
        #expect(model.replyTarget?.id == newer.id)
        f.store.dismiss(id: newer.id)
        #expect(model.replyTarget?.id == first.id)
    }

    @Test func placementPrefersAboveBesideBelowAndClampsOnNegativeDisplays() throws {
        let screen = CGRect(x: -800, y: 0, width: 800, height: 600)
        let size = CGSize(width: 280, height: 160)
        let low = CGRect(x: -460, y: 30, width: 120, height: 120)
        let above = PeekPlacement.place(art: low, anchorX: low.midX, contentSize: size, screen: screen)
        #expect(above.tail.edge == .bottom)
        #expect(above.frame.minY == low.maxY + 4)
        #expect(above.frame.minX + above.tail.offset == low.midX)
        let high = CGRect(x: -720, y: 450, width: 120, height: 120)
        let beside = PeekPlacement.place(art: high, anchorX: high.midX, contentSize: size, screen: screen)
        #expect(beside.tail.edge == .leading)
        #expect(beside.frame.minX == high.maxX + 4)
        let centeredHigh = CGRect(x: -460, y: 450, width: 120, height: 120)
        let below = PeekPlacement.place(art: centeredHigh, anchorX: centeredHigh.midX, contentSize: CGSize(width: 500, height: 160), screen: screen)
        #expect(below.tail.edge == .top)
        #expect(below.frame.maxY == centeredHigh.minY - 4)
        let enormous = PeekPlacement.place(art: high, anchorX: high.midX, contentSize: CGSize(width: 900, height: 900), screen: screen)
        #expect(enormous.tail.edge == .bottom)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(enormous.frame))
        let character = try #require(CharacterLibrary.load(userDirectory: nil).character(id: "zeus"))
        let art = try #require(SpriteLayout.artBounds(character: character))
        #expect(art.maxY < CGFloat(character.canvasSize.height))
        #expect(art.width > 0 && art.height > 0)
    }
}
