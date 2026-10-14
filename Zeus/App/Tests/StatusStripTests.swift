import Foundation
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class StripMessages: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}

@MainActor struct StatusStripTests {
    private func card(_ id: String, at: Double = 1, kind: Card.Kind = .question, options: [CardOption] = [], input: InputSpec? = nil) -> Card {
        Card(id: id, kind: kind, title: id, body: "Body", options: options, input: input, createdAt: Date(timeIntervalSince1970: at))
    }
    @Test func allRowsAndThePMsPrecedenceUseOnlySnapshots() {
        let q = card("question"), unread = card("unread", kind: .message)
        let prompt = card("managed-block_native", kind: .content, options: [.init(id: "native-choice", label: "Allow"), .init(id: "open-terminal", label: "Open in Terminal")])
        var cards = StatusStripState.Cards(values: [q, unread, prompt], seen: [q.id, prompt.id])
        var status = StatusStripState.Status(avatar: .init(state: .working), deliveryProblem: true, quietUntil: "8:00")
        var managed = StatusStripState.Managed(enabled: true, status: .blocked(reason: "Permission"), hasTerminal: true, canStartNew: false)
        let activity = ConversationActivityPresentation(phase: .working, agentName: "Claude", detail: "Claude is working on tests", progress: nil)
        func model(_ activity: ConversationActivityPresentation? = nil) -> ZeusStatusStripModel {
            StatusStripState.make(cards: cards, status: status, managed: managed, activity: activity)
        }
        #expect(model(activity).sentence == "Waiting for your answer" && model(activity).actionTitle == "Go to prompt")
        #expect(model(activity).skipTitle == nil && StatusStripState.jump(cards: cards, status: status, managed: managed, activity: activity) == .prompt(prompt.id))
        cards.values.removeAll { $0.id == prompt.id }
        #expect(model().sentence == "Waiting for you in Terminal" && model().actionTitle == "Open")
        managed.status = .running(.idle)
        #expect(model(activity).sentence == "Unread" && model(activity).glyph == .alert)
        cards.seen.insert(unread.id)
        #expect(model(activity).sentence == activity.label && model(activity).skipTitle == nil)
        status.avatar = .init(state: .waiting)
        #expect(model().sentence == "Waiting for your answer" && model().skipTitle == "Skip")
        cards.values = []
        #expect(model().sentence == "Message not delivered" && model().actionTitle == "Show")
        status.deliveryProblem = false; status.avatar = .init(state: .sleeping)
        #expect(model().sentence == "Quiet until 8:00" && model().isQuiet && model().actionTitle == nil)
        status.quietUntil = nil
        #expect(model().sentence == "Quiet hours")
        status.avatar = .init(state: .idle)
        #expect(model().sentence == "Idle" && model().isQuiet)
        #expect(StatusStripState.jump(cards: cards, status: status, managed: managed, activity: nil) == nil)
        #expect(model().buttons.first { $0.button == .clear }?.isEnabled == false)
    }
    @Test func multipleUnreadsQuestionsButtonsAndOverrideActivityCopy() {
        let a = card("a"), b = card("b", at: 2)
        var cards = StatusStripState.Cards(values: [a,b], canClear: false)
        let idle = StatusStripState.Status(avatar: .init(state: .idle))
        let own = StatusStripState.Managed()
        var result = StatusStripState.make(cards: cards, status: idle, managed: own, activity: nil)
        #expect(result.sentence == "2 unread" && result.buttons.map(\.button) == [.clear,.settings])
        #expect(result.buttons.first?.isEnabled == false)
        cards.seen = [a.id,b.id]
        result = StatusStripState.make(cards: cards, status: idle, managed: own, activity: nil)
        #expect(result.sentence == "2 questions" && result.actionTitle == "Go to oldest")
        let managed = StatusStripState.Managed(enabled: true, status: .running(.idle), hasTerminal: true, canStartNew: false)
        result = StatusStripState.make(cards: cards, status: idle, managed: managed, activity: nil)
        #expect(result.buttons.map(\.button) == [.terminal,.newConversation,.clear,.settings])
        #expect(result.buttons.first { $0.button == .newConversation }?.isEnabled == false)
        let working = StatusStripState.Status(avatar: .init(state: .working, detail: "Building"))
        #expect(StatusStripState.make(cards: cards, status: working, managed: own, activity: nil).sentence == "Building")
    }
    @Test func jumpsCycleChronologicallyAcrossPagingAndRemovedQuestions() {
        let a = card("oldest", at: 1, options: [.init(id: "same", label: "One")])
        var b = card("second", at: 1, input: InputSpec()); b.priority = .high
        let c = card("newest", at: 3)
        var snapshot = StatusStripState.Cards(values: [c,a,b], seen: [a.id,b.id,c.id])
        #expect(StatusStripState.questions(snapshot).map(\.id) == [a.id,b.id,c.id])
        #expect(StatusStripState.nextQuestion(cards: snapshot, after: nil) == a.id)
        #expect(StatusStripState.nextQuestion(cards: snapshot, after: a.id) == b.id)
        #expect(StatusStripState.nextQuestion(cards: snapshot, after: c.id) == a.id)
        snapshot.values.removeAll { $0.id == b.id }
        #expect(StatusStripState.nextQuestion(cards: snapshot, after: b.id) == a.id)
        #expect(StatusStripState.firstControl(a) == .init(entryID: "card:oldest", controlID: "option:same"))
        #expect(StatusStripState.firstControl(b) == .init(entryID: "card:second", controlID: "reply"))
        #expect(StatusStripState.avatarTarget(cards: snapshot, status: .init(state: .waiting)) == .question(a.id))
        snapshot.seen.remove(c.id)
        #expect(StatusStripState.avatarTarget(cards: snapshot, status: .init(state: .alert)) == .unread(c.id))
        #expect(StatusStripState.avatarTarget(cards: snapshot, status: .init(state: .thinking)) == nil)
    }
    @Test func failedBubblePrecedesQueuedAndPendingReplies() {
        let a = card("queued", at: 1, kind: .userMessage), b = card("failed", at: 2, kind: .userMessage)
        var snapshot = StatusStripState.Cards(values: [a,b], outgoing: [a.id: .queued("Offline"), b.id: .failed("Not sent")])
        let status = StatusStripState.Status(avatar: .init(state: .idle), deliveryProblem: true)
        #expect(StatusStripState.jump(cards: snapshot, status: status, managed: .init(), activity: nil) == .failed(b.id))
        snapshot.outgoing.removeValue(forKey: b.id)
        #expect(StatusStripState.jump(cards: snapshot, status: status, managed: .init(), activity: nil) == .failed(a.id))
    }
    @Test func skipIsDurableOnceDoesNotMakeAnEmptyAnswerBubbleAndCannotAnswerNativePrompts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-tb1-skip-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cards.json"), store = CardStore(fileURL: file)
        let question = card("ordinary", options: [.init(id: "yes", label: "Yes")])
        let native = card("managed-block_permission", kind: .content, options: [.init(id: "allow", label: "Allow")])
        let draft = card("managed-block_draft_x", kind: .content, options: [.init(id: "discard", label: "Discard")])
        store.add(question); store.add(native); store.add(draft)
        var routed: [CardResponse] = [], localCalls = 0
        store.responseHandler = { _, response in routed.append(response) }
        store.localActionHandler = { _, _ in localCalls += 1; return false }
        #expect(!store.skip(id: native.id) && !store.skip(id: draft.id) && localCalls == 0)
        #expect(store.skip(id: question.id))
        #expect(routed.count == 1 && routed[0].skipped && routed[0].optionID == nil && routed[0].optionLabel == nil && routed[0].text == nil)
        #expect(!store.skip(id: question.id) && store.card(id: question.id)?.status == .answered)
        let restored = CardStore(fileURL: file)
        #expect(restored.card(id: question.id)?.response?.skipped == true)
        let thread = ConversationModel(cards: restored, messaging: StripMessages()).thread
        #expect(thread.count == 3 && !thread.contains { if case .userAnswer = $0.content { return true }; return false })
        #expect(store.seenIDs.contains(question.id))
    }
    @Test func failedSkipPersistenceDoesNotCloseOrRouteAndExplicitRetryRemainsPossible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-tb1-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json")), q = card("question")
        store.add(q)
        try FileManager.default.removeItem(at: root); try Data("blocked parent".utf8).write(to: root)
        var calls = 0; store.responseHandler = { _, _ in calls += 1 }
        #expect(!store.skip(id: q.id) && calls == 0 && store.card(id: q.id)?.status == .open && store.card(id: q.id)?.response == nil)
        #expect(!store.seenIDs.contains(q.id))
        try FileManager.default.removeItem(at: root)
        #expect(store.skip(id: q.id) && calls == 1)
    }
    @Test func questionJumpRearmsOptionsOnlyAndNewQuestionStillWins() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-tb1-reply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json")), model = ConversationModel(cards: store, messaging: StripMessages())
        let a = card("oldest", options: [.init(id: "yes", label: "Yes")]), b = card("newer", at: 2, input: InputSpec())
        store.add(a); store.add(b); model.beginPlainMessage(); model.rearmReplyTarget(cardID: a.id)
        #expect(model.replyTarget?.id == a.id)
        store.add(card("new arrival", at: 3, input: InputSpec()))
        #expect(model.replyTarget?.id == "new arrival")
    }
    @Test func avatarWaitingSurvivesOpeningThePanelUntilAnsweredOrSkipped() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-tb1-avatar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json")), q = card("question")
        store.add(q); store.markSeen(id: q.id)
        let status = AvatarStatusModel(cards: store)
        #expect(status.state == .waiting)
        store.setConversationOpen(true)
        #expect(status.state == .waiting)
        #expect(store.skip(id: q.id) && status.state == .idle)
    }
}
