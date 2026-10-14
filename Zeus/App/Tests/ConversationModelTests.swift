import Foundation
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor
private final class ConversationMessagingFake: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var calls: [String] = []
    var outcome: MessageSendResult = .delivered
    var hold = false
    var waiter: CheckedContinuation<MessageSendResult, Never>?
    func sendUserMessage(_ text: String) async -> MessageSendResult {
        calls.append(text)
        if hold { return await withCheckedContinuation { waiter = $0 } }
        return outcome
    }
}

@MainActor
private final class ConversationFixture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-conversation-tests-\(UUID())").appendingPathComponent("cards.json")
    let clock = TestClock()
    let messaging = ConversationMessagingFake()
    let cards: CardStore
    let model: ConversationModel
    let status: AvatarStatusModel
    init() {
        let clock = clock
        cards = CardStore(fileURL: url, clock: { clock.now })
        model = ConversationModel(cards: cards, messaging: messaging, clock: { clock.now })
        status = AvatarStatusModel(cards: cards, clock: { clock.now })
    }
    func card(_ kind: Card.Kind = .message, text: String = "Message", input: Bool = false,
              options: [CardOption] = [], priority: Card.Priority = .normal) -> Card {
        Card(kind: kind, body: text, options: options, input: input ? InputSpec() : nil,
             priority: priority, createdAt: clock.now, updatedAt: clock.now)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

@MainActor
struct ConversationModelTests {
    @Test func multilineOutgoingBubbleRetainsLeadingAndBlankLinesAcrossReloadAndClearsComposer() async throws {
        let f = ConversationFixture(); defer { f.cleanup() }
        f.model.draft = "\r\n  first\r\n\r\nlong wrapped line\r\nlast\t \r\n"
        let expected = "\n  first\n\nlong wrapped line\nlast"
        await f.model.send()
        #expect(f.messaging.calls == [expected])
        #expect(f.model.draft.isEmpty)
        #expect(f.model.thread.count == 1)
        #expect(f.model.thread.first?.body == expected)
        let saved = try #require(CardStore(fileURL: f.url).cards.first { $0.kind == .userMessage })
        #expect(saved.body == expected)
        let rendered = ZeusMarkdown.attributed(saved.body, choice: .pixel, palette: .light)
        #expect(String(rendered.characters) == expected, "The bubble's markdown path keeps the line breaks too")
    }

    @Test func threadChronologyIncludesOldAnswersAndOutgoingMessagesOnce() async {
        let f = ConversationFixture(); defer { f.cleanup() }
        let first = f.card(text: "First"); f.cards.add(first)
        f.clock.advance(1)
        let question = f.card(.question, text: "Ready?", input: true, options: [CardOption(id: "yes", label: "Yes")]); f.cards.add(question)
        f.clock.advance(1)
        let newer = f.card(text: "Newer", priority: .high); f.cards.add(newer)
        f.clock.advance(1)
        f.model.clearReplyTarget()
        await f.model.send("A plain message")
        f.clock.advance(1)
        var replies = 0
        f.cards.responseHandler = { card, _ in #expect(card.id == question.id); replies += 1 }
        #expect(f.model.pickOption(cardID: question.id, optionID: "yes"))
        #expect(!f.model.pickOption(cardID: question.id, optionID: "yes"))
        let thread = f.model.thread
        #expect(thread.map(\.body) == ["First", "Ready?", "Newer", "A plain message", "Yes"])
        #expect(thread.map(\.isUser) == [false, false, false, true, true])
        #expect(Set(thread.map(\.id)).count == 5)
        #expect(thread.last?.sourceCardID == question.id)
        #expect(thread.last?.outcome == .recordedReply)
        #expect(replies == 1)
        let restored = CardStore(fileURL: f.url, clock: { f.clock.now })
        let model = ConversationModel(cards: restored, messaging: f.messaging)
        #expect(model.thread.map(\.id) == thread.map(\.id))
        #expect(model.thread.map(\.body) == thread.map(\.body))
    }

    @Test func dismissingAnAnsweredCardMutesItsSourceAndKeepsTheAnswerEcho() {
        let f = ConversationFixture(); defer { f.cleanup() }
        let question = f.card(.question, options: [CardOption(id: "yes", label: "Yes")])
        f.cards.add(question)
        #expect(f.model.pickOption(cardID: question.id, optionID: "yes"))
        f.cards.dismiss(id: question.id)
        #expect(f.model.thread.count == 2)
        #expect(f.model.thread[0].isMuted)
        #expect(f.model.thread[1].body == "Yes")
        #expect(!f.model.thread[1].isMuted)
        #expect(!f.model.pickOption(cardID: question.id, optionID: "yes"))
    }

    @Test func updatesKeepEntryIdentityAndDismissalMutesRatherThanRemoves() {
        let f = ConversationFixture(); defer { f.cleanup() }
        let progress = f.card(.progress, text: "Working"); f.cards.add(progress)
        let id = f.model.thread[0].id
        f.clock.advance(1)
        f.cards.update(id: progress.id) { $0.body = "Almost done"; $0.progress = 0.9 }
        #expect(f.model.thread.count == 1)
        #expect(f.model.thread[0].id == id)
        #expect(f.model.thread[0].body == "Almost done")
        #expect(f.model.thread[0].timestamp == progress.createdAt)
        f.cards.dismiss(id: progress.id)
        #expect(f.model.thread.count == 1)
        #expect(f.model.thread[0].isMuted)
        #expect(f.model.unseenCount == 1)
    }

    @Test func openingMarksAllAgentMessagesSeenAndIncomingOpenPanelMessagesStaySeen() {
        let f = ConversationFixture(); defer { f.cleanup() }
        let first = f.card(), second = f.card(.question, input: true)
        f.cards.add(first); f.cards.add(second)
        f.cards.dismiss(id: first.id)
        #expect(f.model.unseenCount == 2)
        #expect(f.status.badgeCount == 2)
        #expect(f.status.state == .alert)
        f.model.openPanel()
        #expect(f.model.isPanelOpen)
        #expect(f.model.unseenCount == 0)
        #expect(f.status.state == .idle)
        #expect(CardStore(fileURL: f.url).unseenCount == 0)
        f.cards.add(f.card(text: "Arrived while reading"))
        #expect(f.model.unseenCount == 0)
        f.cards.add(Card(kind: .userMessage, body: "Mine", status: .answered))
        #expect(f.model.unseenCount == 0)
        f.model.closePanel()
        #expect(!f.model.isPanelOpen)
        #expect(f.status.state == .waiting)
        f.cards.add(f.card(text: "Arrived while closed"))
        #expect(f.model.unseenCount == 1)
        #expect(f.status.state == .alert)
    }

    @Test func attentionOverridesClearOnOpenAndAnsweredQuestionStopsWaiting() {
        let f = ConversationFixture(); defer { f.cleanup() }
        let question = f.card(.question, input: true); f.cards.add(question)
        f.status.noteNewCard(Card(kind: .question, body: "Question", mood: .waiting))
        f.status.setOverride(.alert, detail: nil, progress: nil, ttl: 60)
        f.model.openPanel()
        #expect(f.status.state == .idle)
        f.status.setOverride(.working, detail: "Building", progress: 0.5, ttl: 60)
        #expect(f.status.state == .working)
        f.status.setOverride(.waiting, detail: nil, progress: nil, ttl: 60)
        f.model.closePanel()
        #expect(f.status.state == .waiting)
        f.cards.respond(id: question.id, response: CardResponse(text: "Answer", device: .mac))
        #expect(f.status.state == .idle)
        #expect(f.status.badgeCount == 0)
    }

    @Test func composerAnswersOneQuestionDespiteSeveralLaterAgentMessages() async {
        let f = ConversationFixture(); defer { f.cleanup() }
        let question = f.card(.question, input: true); f.cards.add(question)
        f.clock.advance(1); f.cards.add(f.card(text: "More context"))
        f.clock.advance(1); f.cards.add(f.card(text: "And an attachment"))
        var replies = 0
        f.cards.responseHandler = { card, response in
            #expect(card.id == question.id); #expect(response.text == " One reply\nwith a newline"); replies += 1
        }
        f.model.draft = " One reply\nwith a newline "
        let result = await f.model.send()
        #expect(result == .answered(cardID: question.id))
        #expect(f.messaging.calls.isEmpty)
        #expect(f.model.thread.filter(\.isUser).count == 1)
        #expect(f.model.draft.isEmpty)
        #expect(replies == 1)
        #expect(f.cards.cards.filter { $0.kind == .userMessage }.isEmpty)
    }

    @Test func clearChipAndEmptyBackspaceSendPlainMessagesWithoutAnsweringQuestions() async {
        let f = ConversationFixture(); defer { f.cleanup() }
        let old = f.card(.question, input: true); f.cards.add(old)
        f.model.draft = "Editing"
        #expect(!f.model.backspaceInComposer())
        #expect(f.model.replyTarget?.id == old.id)
        f.model.draft = ""
        #expect(f.model.backspaceInComposer())
        #expect(f.model.replyTarget == nil)
        await f.model.send("Plain message")
        #expect(f.messaging.calls == ["Plain message"])
        #expect(f.cards.card(id: old.id)?.response == nil)
        f.clock.advance(1)
        let new = f.card(.question, input: true); f.cards.add(new)
        #expect(f.model.replyTarget?.id == new.id)
        f.model.clearReplyTarget()
        #expect(f.model.replyTarget == nil)
        f.cards.dismiss(id: new.id)
        #expect(f.model.replyTarget == nil) // clearing the older question still applies
    }

    @Test func latestOptionsOnlyQuestionKeepsTheNewestTextAcceptingTarget() async {
        let f = ConversationFixture(); defer { f.cleanup() }
        let textQuestion = f.card(.question, input: true); f.cards.add(textQuestion)
        f.clock.advance(1)
        let optionsQuestion = f.card(.question, options: [CardOption(id: "yes", label: "Yes")]); f.cards.add(optionsQuestion)
        #expect(f.model.newestOpenQuestion?.id == optionsQuestion.id)
        #expect(f.model.replyTarget?.id == textQuestion.id)
        await f.model.send("Answer")
        #expect(f.messaging.calls.isEmpty)
        #expect(f.cards.card(id: textQuestion.id)?.response?.text == "Answer")
    }

    @Test func optionShortcutTargetsNewestQuestionInSuppliedOrderAndBoundsOneToNine() {
        let f = ConversationFixture(); defer { f.cleanup() }
        let old = f.card(.question, options: [CardOption(id: "old", label: "Old")], priority: .high); f.cards.add(old)
        f.clock.advance(1)
        let options = (1...10).map { CardOption(id: "option\($0)", label: "Option \($0)", style: $0 == 2 ? .primary : .secondary) }
        let newest = f.card(.question, options: options); f.cards.add(newest)
        f.clock.advance(1); f.cards.add(f.card(text: "A later message"))
        #expect(!f.model.pickNumberedOption(0))
        #expect(!f.model.pickNumberedOption(10))
        #expect(f.model.pickNumberedOption(9))
        #expect(f.cards.card(id: newest.id)?.response?.optionID == "option9")
        #expect(f.cards.card(id: old.id)?.response == nil)
        #expect(f.model.pickOption(cardID: old.id, optionID: "old"))
        #expect(!f.model.pickOption(cardID: old.id, optionID: "missing"))
    }

    @Test func actionsOnOldContentCardsStillWorkAndExpiredTextReplyIsNotSentElsewhere() async {
        let f = ConversationFixture(); defer { f.cleanup() }
        let content = f.card(.content, options: [CardOption(id: "revise", label: "Revise")]); f.cards.add(content)
        f.clock.advance(1); f.cards.add(f.card(text: "Later"))
        #expect(f.model.pickOption(cardID: content.id, optionID: "revise"))
        var question = f.card(.question, input: true)
        question.expiresAt = f.clock.now.addingTimeInterval(1)
        f.cards.add(question)
        f.model.draft = "Too late"
        f.clock.advance(2)
        let result = await f.model.send()
        if case .rejected = result {} else { Issue.record("Expected an expired target rejection") }
        #expect(f.messaging.calls.isEmpty)
        #expect(f.model.draft == "Too late")
        #expect(f.cards.card(id: question.id)?.status == .expired)
        #expect(f.model.thread.first { $0.sourceCardID == question.id }?.isMuted == true)
    }

    @Test func plainMessageOutcomesRemainOnTheirOwnBubbles() async {
        let f = ConversationFixture(); defer { f.cleanup() }
        f.model.draft = "   "
        #expect(await f.model.send() == nil)
        #expect(f.model.thread.isEmpty)
        for outcome in [MessageSendResult.delivered, .queued(reason: "Offline"), .failed(reason: "No target")] {
            f.messaging.outcome = outcome
            f.model.draft = "Message \(f.messaging.calls.count)"
            await f.model.send()
            #expect(f.model.thread.last?.outcome == .delivery(outcome))
            if case .failed = outcome { #expect(!f.model.draft.isEmpty) } else { #expect(f.model.draft.isEmpty) }
            f.clock.advance(1)
        }
        #expect(f.messaging.calls.count == 3)
        #expect(f.model.thread.count == 3)
        #expect(f.model.unseenCount == 0)
    }

    @Test func concurrentSendIsGuardedAndNewQuestionCannotConsumeAnInflightMessage() async throws {
        let f = ConversationFixture(); defer { f.cleanup() }
        f.messaging.hold = true
        f.model.draft = "Original plain message"
        let pending = Task { await f.model.send() }
        for _ in 0..<100 where f.messaging.waiter == nil { await Task.yield() }
        let waiter = try #require(f.messaging.waiter)
        #expect(f.model.isSending)
        #expect(f.model.thread.first?.outcome == .sending)
        #expect(await f.model.send("Duplicate click") == nil)
        f.clock.advance(1)
        let question = f.card(.question, input: true); f.cards.add(question)
        f.model.draft = "A new draft"
        waiter.resume(returning: .queued(reason: "Offline"))
        _ = await pending.value
        #expect(f.messaging.calls == ["Original plain message"])
        #expect(f.cards.card(id: question.id)?.response == nil)
        #expect(f.model.thread.filter(\.isUser).count == 1)
        #expect(f.model.draft == "A new draft")
        #expect(!f.model.isSending)
    }

    @Test func tiedTimestampsHaveStableOrderingAndNewestQuestionUsesArrivalOrder() {
        let f = ConversationFixture(); defer { f.cleanup() }
        let old = f.card(.question, input: true), new = f.card(.question, input: true)
        f.cards.add(old); f.cards.add(new)
        #expect(f.model.newestOpenQuestion?.id == new.id)
        f.cards.respond(id: old.id, response: CardResponse(text: "Answer", respondedAt: f.clock.now, device: .ios))
        #expect(f.model.thread.map(\.body) == [old.body, new.body, "Answer"])
        #expect(f.model.thread.last?.isUser == true)
    }
}
