import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Observable final class FB1RatingsFake: MessageRatingsProviding {
    var ratings: [MessageRating] = []
    var mutedToday: [String] = []
    var mutedDecisions: [String: CardMuteDecision] = [:]
    var ratingSuggestions: [RatingSuggestion] = []
    var ratingsRevision: UInt64 = 0
    var ratingsError: String?
    var onShowMuted: (([String]) -> Void)?
    var fail = false
    var opened: [String] = []
    var shown: [String] = []
    var dismissed: [String] = []
    private var tokens: [String: MessageRatingUndo] = [:]
    private var undo: [UUID: ([MessageRating], [String: CardMuteDecision])] = [:]
    enum Failure: Error { case unavailable, stale }
    private func checkpoint(_ id: String) throws -> MessageRatingUndo {
        if fail { throw Failure.unavailable }
        let token = MessageRatingUndo(id: UUID()); undo[token.id] = (ratings, mutedDecisions)
        tokens[id] = token; return token
    }
    func rate(cardID: String, rating: MessageRatingValue, scope: MessageRatingScope, label: String) async throws -> MessageRatingUndo {
        let id = UUID().uuidString, token = try checkpoint(id)
        ratings.append(.init(id: id, kindLabel: label, kindKey: label.lowercased(), rating: rating, scope: scope, exampleCardID: cardID,
                             exampleText: "You're on call from 22:00. The pager is set to loud.", createdAt: .now, updatedAt: .now))
        ratingsRevision += 1; return token
    }
    func update(id: String, rating: MessageRatingValue, scope: MessageRatingScope, label: String) async throws -> MessageRatingUndo {
        let token = try checkpoint(id)
        if let index = ratings.firstIndex(where: { $0.id == id }) {
            ratings[index].rating = rating; ratings[index].scope = scope; ratings[index].kindLabel = label
            ratings[index].kindKey = label.lowercased()
        }
        ratingsRevision += 1; return token
    }
    func remove(id: String) async throws -> MessageRatingUndo {
        let token = try checkpoint(id); ratings.removeAll { $0.id == id }; ratingsRevision += 1; return token
    }
    func undoRating(_ receipt: MessageRatingUndo) async throws {
        if fail { throw Failure.unavailable }
        guard tokens.values.contains(where: { $0.id == receipt.id }), let saved = undo[receipt.id] else { throw Failure.stale }
        ratings = saved.0; mutedDecisions = saved.1; tokens = tokens.filter { $0.value.id != receipt.id }; ratingsRevision += 1
    }
    func ratingUndo(for id: String) -> MessageRatingUndo? { tokens[id] }
    func correctMuted(cardID: String) async throws -> MessageRatingUndo {
        let token = try checkpoint(cardID); mutedDecisions[cardID]?.releasedAt = .now
        mutedToday.removeAll { $0 == cardID }; ratingsRevision += 1; return token
    }
    func showMuted() { onShowMuted?(mutedToday) }
    func dismissRatingSuggestion(id: String) throws {
        if fail { throw Failure.unavailable }; ratingSuggestions.removeAll { $0.id == id }; ratingsRevision += 1
    }
    func ratingCardShown(id: String) { shown.append(id) }
    func ratingCardOpened(id: String) { opened.append(id) }
    func ratingCardDismissed(id: String) { dismissed.append(id) }
}

@MainActor @Suite(.serialized) struct FB1RatingsTests {
    static func card(_ id: String = "rating-card", origin: CardOrigin? = .unprompted) -> Card {
        var card = Card(id: id, kind: .message, title: "On-call tonight", body: "You're on call from 22:00. The pager is set to loud.")
        card.origin = origin; card.about = "On-call reminders"; return card
    }
    private func fixture() -> (URL, CardStore, FB1RatingsFake, MessageRatingsModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb1-app-\(UUID())")
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        return (root, cards, fake, MessageRatingsModel(cards: cards, source: { fake }))
    }
    @Test func onlyRuntimeClassifiedUnpromptedCardsGetRatings() {
        let (_, cards, fake, model) = fixture()
        for origin in [CardOrigin.reply, nil] { #expect(!model.canRate(Self.card(origin: origin))) }
        #expect(model.canRate(Self.card()))
        var local = Self.card(); local.kind = .userMessage; #expect(!model.canRate(local))
        local.kind = .progress; #expect(!model.canRate(local))
        #expect(!MessageRatingsModel(cards: cards).canRate(Self.card()))
        #expect(fake.ratings.isEmpty)
    }
    @Test func inlineScopeLabelUndoAndReloadUseProviderState() async throws {
        let (root, cards, fake, model) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let card = Self.card(); cards.add(card); model.begin(card)
        model.editLabel(card.id); model.setLabel("", id: card.id); model.finishLabel(card.id)
        #expect(model.drafts[card.id]?.label == "On-call reminders")
        model.setScope(.justThisOne, id: card.id); await model.rate(.down, card: card)
        #expect(fake.ratings.first?.scope == .justThisOne && model.drafts[card.id] == nil)
        #expect(model.confirmation(for: card)?.text == "Not this one")
        let reopened = MessageRatingsModel(cards: cards, source: { fake })
        #expect(reopened.confirmation(for: card)?.receipt != nil)
        await reopened.undo(card.id); #expect(fake.ratings.isEmpty)
        model.begin(card); await model.rate(.neutral, card: card)
        #expect(fake.ratings.first?.scope == .kind)
        #expect(model.confirmation(for: card)?.text == "Only when I need to know: On-call reminders")
    }
    @Test func failedWriteKeepsEditorAndDoesNotClaimSuccess() async {
        let (root, cards, fake, model) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let card = Self.card(); cards.add(card); model.begin(card); fake.fail = true
        await model.rate(.down, card: card)
        #expect(model.drafts[card.id] != nil && model.errors[card.id] != nil)
        #expect(model.confirmation(for: card) == nil && fake.ratings.isEmpty && model.busy.isEmpty)
    }
    @Test func mutedHighPriorityStaysQuietAndCorrectionIsPerCard() async throws {
        let (root, cards, fake, model) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var card = Self.card(); card.kind = .question; card.priority = .high
        card.muteDecision = .init(ratingID: "stop", kindLabel: "On-call reminders", reason: "looks like On-call reminders", engine: "embedding", score: 0.9, threshold: 0.8, decidedAt: .now)
        fake.mutedDecisions[card.id] = card.muteDecision; fake.mutedToday = [card.id]; cards.add(card)
        #expect(model.isCollapsed(card) && cards.unseenCount == 0 && !cards.hasOpenQuestion)
        #expect(!PeekModel.eligible(card))
        #expect(StatusStripState.unread(.init(values: cards.cards)).isEmpty)
        #expect(ConversationModel(cards: cards, messaging: AgentMessagingHub()).replyTarget == nil)
        model.show(card.id); #expect(!model.isCollapsed(card) && model.isHeld(card))
        await model.correct(card); #expect(!model.isHeld(card)); #expect(model.confirmation(for: card)?.receipt != nil)
        await model.undo(card.id); #expect(model.isHeld(card))
    }
    @Test func settingsEditsRemoveAndUndoUpdateLiveBubble() async throws {
        let (root, cards, fake, model) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let card = Self.card(); cards.add(card); model.begin(card); await model.rate(.up, card: card)
        let rating = try #require(fake.ratings.first)
        await model.update(rating, value: .down, label: "Pager alerts")
        #expect(model.confirmation(for: card)?.text == "Stopped: Pager alerts")
        await model.remove(try #require(fake.ratings.first)); #expect(model.confirmation(for: card) == nil)
        await model.undo(rating.id); #expect(fake.ratings.first?.kindLabel == "Pager alerts")
    }
    @Test func dailySummaryAndSuggestionAreQuietDurableNavigation() throws {
        let (root, cards, fake, model) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000), start = calendar.startOfDay(for: day)
        var card = Self.card(); card.muteDecision = .init(ratingID: "stop", kindLabel: "On-call reminders", reason: "same", engine: "exact", score: 1, threshold: 1, decidedAt: start)
        cards.add(card); fake.mutedDecisions[card.id] = card.muteDecision; fake.mutedToday = [card.id]
        model.reconcile(now: start.addingTimeInterval(20 * 3600), calendar: calendar); #expect(cards.notices.isEmpty)
        model.reconcile(now: start.addingTimeInterval(21 * 3600), calendar: calendar)
        model.reconcile(now: start.addingTimeInterval(22 * 3600), calendar: calendar)
        #expect(cards.notices.count == 1 && cards.notices.first?.summary == "1 muted message today")
        var target: String?; model.openCard = { target = $0 }
        cards.performNoticeAction(id: try #require(cards.notices.first?.id))
        #expect(target == card.id && !model.isCollapsed(card) && model.isHeld(card))
        fake.ratingSuggestions = [.init(id: "suggestion", kindLabel: "On-call reminders", count: 5, exampleCardID: card.id)]
        model.reconcile(now: start.addingTimeInterval(22 * 3600), calendar: calendar)
        #expect(cards.notices.contains { $0.secondaryTitle == "Not now" })
        cards.performSecondaryNoticeAction(id: "rating-suggestion-suggestion"); #expect(fake.ratingSuggestions.isEmpty)
        fake.mutedDecisions[card.id]?.releasedAt = day
        model.reconcile(now: start.addingTimeInterval(22 * 3600), calendar: calendar)
        #expect(cards.notices.isEmpty, "Released messages leave no stale daily summary or action")
    }
}
