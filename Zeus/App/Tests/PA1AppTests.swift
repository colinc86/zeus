import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

extension FB1RatingsFake: ProactiveAssistantControlling {
    func noteProactiveActivity(at date: Date) {}
    func proactiveSettingsDidChange() {}
}

@MainActor @Suite(.serialized) struct PA1AppTests {
    /// A message 0.3.8 held over its removed daily limit, as saved in old history.
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
    @Test func legacyDailyLimitDecisionIsNeverShownAsHeld() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa1-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let model = MessageRatingsModel(cards: cards, source: { fake }), card = Self.card()
        cards.add(card); fake.mutedDecisions[card.id] = card.muteDecision
        #expect(model.decision(card) == nil)
        #expect(!model.isHeld(card) && !model.isCollapsed(card) && model.canRate(card))
        #expect(model.confirmation(for: card) == nil)
        model.begin(card)
        #expect(model.drafts[card.id] != nil)
    }
    @Test func dailySummaryCountsOnlyRatingMutes() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa1-summary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let model = MessageRatingsModel(cards: cards, source: { fake }), card = Self.card()
        model.dailyHour = { 0 }
        cards.add(card)
        model.reconcile()
        #expect(!cards.notices.contains { $0.id.hasPrefix("rating-muted-") })
        fake.mutedDecisions[card.id] = card.muteDecision
        model.reconcile()
        #expect(!cards.notices.contains { $0.id.hasPrefix("rating-muted-") })
        fake.mutedDecisions[card.id]?.source = .rating
        model.reconcile()
        #expect(cards.notices.contains { $0.summary == "1 muted message today" })
        #expect(!cards.notices.contains { $0.summary.contains("held") })
    }
    /// Regression: history saved by 0.3.8 holds messages over the removed daily limit. They load as ordinary messages.
    @Test func cardStoreReleasesDailyLimitHoldsOnLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa1-release-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cards.json")
        var rated = FB1RatingsTests.card("rating-muted")
        rated.muteDecision = .init(ratingID: "r1", kindLabel: "On-call reminder", reason: "kind: On-call reminder", engine: "exact",
                                   score: 1, threshold: 1, decidedAt: .now, source: .rating)
        do {
            let old = CardStore(fileURL: url)
            old.add(Self.card()); old.add(rated)
            #expect(old.cards.first?.isRatingHeld == true)
            #expect(old.unseenCount == 0)
        }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("dailyBudget"))
        let cards = CardStore(fileURL: url)
        #expect(cards.persistenceError == nil)
        let released = try #require(cards.card(id: Self.card().id))
        #expect(released.muteDecision == nil && !released.isRatingHeld)
        #expect(PeekModel.eligible(released))
        #expect(cards.unseenCount == 1)
        // A rating mute is the user's choice and stays.
        #expect(cards.card(id: rated.id)?.muteDecision?.source == .rating)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("dailyBudget"))
        let model = MessageRatingsModel(cards: cards, source: { FB1RatingsFake() })
        #expect(!model.isHeld(released) && !model.isCollapsed(released))
    }
}
