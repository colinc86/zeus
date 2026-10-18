import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

extension FB1RatingsFake: ProactiveAssistantControlling {
    func noteProactiveActivity(at date: Date) {}
    func proactiveSettingsDidChange() {}
    func showBudgetHeldCard(id: String) throws {
        if fail { throw Failure.unavailable }
        guard mutedDecisions[id]?.source == .dailyBudget else { throw Failure.stale }
        mutedDecisions[id]?.releasedAt = .now; ratingsRevision += 1
    }

}

@MainActor @Suite(.serialized) struct PA1AppTests {
    static func card() -> Card {
        var card = FB1RatingsTests.card("budget-held")
        card.muteDecision = .init(ratingID: "", kindLabel: "", reason: "daily budget", engine: "budget",
                                  score: 1, threshold: 6, decidedAt: .now, source: .dailyBudget)
        return card
    }
    @Test func proactivePendingRowsNeverClaimAReceipt() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa1-waiting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = LM4Controller()
        let model = LearningDeliveryModel(cards: cards, source: { fake })
        fake.pendingLearningDeliveries = [
            .init(id: "brief", kind: .brief, text: "Synthetic brief request", preparedAt: .now, sessionLabel: "Assistant"),
            .init(id: "rule", kind: .ruleTrigger, text: "Synthetic rule trigger", preparedAt: .now, sessionLabel: "Assistant")
        ]
        model.reconcile()
        #expect(cards.notices.contains { $0.summary == "Morning brief request ready for your assistant" })
        #expect(cards.notices.contains { $0.summary == "Rule trigger ready for your assistant" })
        #expect(!cards.notices.contains { $0.summary.hasPrefix("Sent") })
        #expect(WaitingLearningRow(item: fake.pendingLearningDeliveries[0], hold: nil, now: .now).title == "Morning brief request")
        #expect(WaitingLearningRow(item: fake.pendingLearningDeliveries[1], hold: nil, now: .now).title == "Rule trigger")
    }
    @Test func budgetShowHidePreservesRatingAndFailedReleaseStaysCollapsed() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa1-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let model = MessageRatingsModel(cards: cards, source: { fake }), card = Self.card()
        cards.add(card); fake.mutedDecisions[card.id] = card.muteDecision
        #expect(model.isBudgetHeld(card) && model.isCollapsed(card) && model.canRate(card))
        fake.fail = true; model.show(card.id)
        #expect(model.isCollapsed(card) && model.errors[card.id] != nil)
        fake.fail = false; model.show(card.id)
        #expect(!model.isCollapsed(card) && model.isHeld(card) && model.errors[card.id] == nil)
        #expect(fake.ratings.isEmpty)
        model.hide(card.id); #expect(model.isCollapsed(card))
        #expect(fake.mutedDecisions[card.id]?.releasedAt != nil)
        model.showMuted([card.id]); #expect(!model.isCollapsed(card))
        model.hide(card.id); model.begin(card)
        #expect(!model.isCollapsed(card) && model.drafts[card.id] != nil)
    }
    @Test func dailySummaryUsesHeldForAMixedGroupAndMutedForRatingsOnly() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa1-summary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let model = MessageRatingsModel(cards: cards, source: { fake }), card = Self.card()
        model.dailyHour = { 0 }
        cards.add(card)
        model.reconcile() // Budget decisions live on cards, independently of the ratings store.
        #expect(cards.notices.contains { $0.summary == "1 held message today" })
        fake.mutedDecisions[card.id] = card.muteDecision
        model.reconcile()
        #expect(cards.notices.contains { $0.summary == "1 held message today" })
        model.show(card.id); model.reconcile()
        #expect(cards.notices.contains { $0.summary == "1 held message today" })
        fake.mutedDecisions[card.id]?.releasedAt = nil
        fake.mutedDecisions[card.id]?.source = .rating
        model.reconcile()
        #expect(cards.notices.contains { $0.summary == "1 muted message today" })
    }
}
