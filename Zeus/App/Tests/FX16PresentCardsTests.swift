import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private final class FX16Messaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}

/// FX16: present cards aren't questions; withdrawn cards aren't unread (CONVERSATION.md §4, §8, §15.2, §20.1).
@MainActor struct FX16PresentCardsTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_100_000)
    private func store(clock: @escaping () -> Date) throws -> (CardStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-fx16-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: clock), root)
    }
    private func present(_ id: String, about: String? = "Prepared work", at: Date? = nil) -> Card {
        Card(id: id, kind: .content, title: "Agenda draft", body: "Here's the draft.",
             options: [CardOption(id: "ok", label: "Looks good", style: .primary), CardOption(id: "rev", label: "Revise")],
             sessionKey: "claude:/tmp/a", createdAt: at ?? t0, updatedAt: at ?? t0, about: about)
    }

    @Test func presentCardNeverMakesZeusWaitButStaysAnswerable() throws {
        var now = t0
        let (cards, root) = try store(clock: { now }); defer { try? FileManager.default.removeItem(at: root) }
        cards.add(present("c_p")); cards.markAllSeen()
        #expect(!cards.hasOpenQuestion)
        let strip = StatusStripState.make(cards: .init(values: cards.cards, seen: cards.seenIDs), status: .init(avatar: .init(state: .idle)), managed: .init(), activity: nil)
        #expect(strip.sentence == "Idle" && strip.skipTitle == nil)
        #expect(StatusStripState.questions(.init(values: cards.cards)).isEmpty)
        #expect(AvatarStatusModel(cards: cards, clock: { now }).resolve(at: now).state == .idle)
        // Still answerable: ⌘N, the buttons (respond) and Skip.
        let model = ConversationModel(cards: cards, messaging: FX16Messaging(), clock: { now })
        #expect(model.shortcutTarget?.id == "c_p" && model.replyTarget == nil)
        let presentCard = try #require(cards.card(id: "c_p"))
        #expect(CardStore.canSkip(presentCard))
        #expect(model.pickNumberedOption(1) && cards.card(id: "c_p")?.response?.optionID == "ok")
        now = t0.addingTimeInterval(60)
        cards.add(present("c_q")); #expect(cards.skip(id: "c_q") && cards.card(id: "c_q")?.response?.skipped == true)
    }

    @Test func questionsAndMirroredPromptsStillWait() throws {
        let (cards, root) = try store(clock: { t0 }); defer { try? FileManager.default.removeItem(at: root) }
        cards.add(Card(id: "c_ask", kind: .question, body: "Ship it?", options: [CardOption(id: "y", label: "Yes")], sessionKey: "claude:/tmp/a", createdAt: t0, updatedAt: t0))
        #expect(cards.hasOpenQuestion)
        _ = cards.respond(id: "c_ask", response: CardResponse(optionID: "y", optionLabel: "Yes", device: .mac))
        #expect(!cards.hasOpenQuestion)
        cards.add(Card(id: CardStore.managedActionPrefix + "native", kind: .content, body: "Allow?", options: [CardOption(id: "allow", label: "Allow")], sessionKey: "claude:/tmp/a", createdAt: t0, updatedAt: t0))
        #expect(cards.hasOpenQuestion && StatusStripState.questions(.init(values: cards.cards)).count == 1)
    }

    @Test func composerReplyClosesOpenHandoversQuietly() async throws {
        let (cards, root) = try store(clock: { t0 }); defer { try? FileManager.default.removeItem(at: root) }
        cards.add(present("c_p1", about: "Prepared work")); cards.add(present("c_p2", about: "Status update"))
        cards.add(Card(id: "c_ask", kind: .question, body: "Ship it?", options: [CardOption(id: "y", label: "Yes")], sessionKey: "claude:/tmp/a", createdAt: t0, updatedAt: t0))
        var replies = 0; cards.responseHandler = { _, _ in replies += 1 }
        let model = ConversationModel(cards: cards, messaging: FX16Messaging(), clock: { t0 })
        model.draft = "thanks, looks good"
        _ = await model.send()
        #expect(cards.card(id: "c_p1")?.status == .dismissed && cards.card(id: "c_p2")?.status == .dismissed)
        #expect(cards.card(id: "c_p1")?.response == nil)  // closed quietly: the assistant hears nothing about the actions
        #expect(cards.card(id: "c_ask")?.status == .answered && replies == 1)  // the composer reply went to the question
        #expect(!cards.hasOpenQuestion)
    }

    @Test func newerHandoverWithTheSameAboutClosesTheOlderOne() throws {
        let (cards, root) = try store(clock: { t0 }); defer { try? FileManager.default.removeItem(at: root) }
        cards.add(present("c_day1", about: "Prepared work"))
        cards.add(present("c_other", about: "Status update"))
        cards.add(present("c_day2", about: "Prepared work", at: t0.addingTimeInterval(86_400)))
        #expect(cards.card(id: "c_day1")?.status == .dismissed)
        #expect(cards.card(id: "c_other")?.status == .open && cards.card(id: "c_day2")?.status == .open)
        cards.add(present("c_none", about: nil)); cards.add(present("c_none2", about: nil))
        #expect(cards.card(id: "c_none")?.status == .open)  // no about, nothing to match
    }

    @Test func withdrawnCardsAreNeverUnread() throws {
        var now = t0
        let (cards, root) = try store(clock: { now }); defer { try? FileManager.default.removeItem(at: root) }
        cards.setConversationOpen(false)
        cards.add(Card(id: "c_prog", kind: .progress, title: "Building", body: "Building…", progress: 0.4, sessionKey: "claude:/tmp/a", createdAt: t0, updatedAt: t0))
        cards.dismiss(id: "c_prog")
        cards.add(Card(id: "c_say", kind: .message, body: "Back in an hour.", sessionKey: "claude:/tmp/a", createdAt: t0, updatedAt: t0, expiresAt: t0.addingTimeInterval(60)))
        cards.add(Card(id: "c_live", kind: .message, body: "Done.", sessionKey: "claude:/tmp/a", createdAt: t0, updatedAt: t0))
        now = t0.addingTimeInterval(3_600); cards.expire()
        #expect(cards.card(id: "c_say")?.status == .expired)
        #expect(cards.unseenCount == 1)
        let strip = StatusStripState.make(cards: .init(values: cards.cards, seen: cards.seenIDs), status: .init(avatar: .init(state: .alert)), managed: .init(), activity: nil)
        #expect(strip.sentence == "Unread" && StatusStripState.unread(.init(values: cards.cards)).map(\.id) == ["c_live"])
        let entries = cards.cards.map { ConversationEntry(id: "card:\($0.id)", timestamp: $0.createdAt, content: .agentCard($0)) }
        let jump = ConversationJumpState.make(entries: entries, visible: ["card:c_live"], seen: [], questions: [], atBottom: true, pending: false, awayFromLatest: false)
        #expect(jump.unreadAbove.isEmpty)
        #expect(ConversationLayout.unseenBelow(entries: entries, visible: ["card:c_prog"], seen: []) == 1)
        let peek = PeekModel(store: cards)
        let progress = try #require(cards.card(id: "c_prog")), say = try #require(cards.card(id: "c_say"))
        #expect(!PeekModel.eligible(progress) && !PeekModel.eligible(say))
        _ = peek
        #expect(AvatarStatusModel(cards: cards, clock: { now }).resolve(at: now).state == .alert)
        cards.markSeen(id: "c_live")
        #expect(cards.unseenCount == 0 && AvatarStatusModel(cards: cards, clock: { now }).resolve(at: now).state == .idle)
    }
}
