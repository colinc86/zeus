import Foundation
import Testing
@testable import Zeus

@MainActor final class LM2DManagedRules: RuleLifecycleStoring {
    let base = LM2RulesFake()
    var rules: [LearnedRule] { base.rules }
    var revision: UInt64 { base.revision }
    var lastError: String? { base.lastError }
    var autonomy: Double { get { base.autonomy } set { base.autonomy = newValue } }
    var outcomeEvents: [RuleOutcomeEvent] = []
    var suppressedRules: [RuleSuppression] = []
    var ruleActions: [RuleActionRecord] = []
    var nextOutcomeBoundary: Date? { nil }
    func propose(_ proposals: [RuleProposal], at now: Date) throws -> [LearnedRule] { try base.propose(proposals, at: now) }
    func addOwn(_ proposal: RuleProposal, at now: Date) throws -> LearnedRule { try base.addOwn(proposal, at: now) }
    func setStatus(_ status: LearnedRuleStatus, id: String, at now: Date) throws { try base.setStatus(status, id: id, at: now) }
    func edit(id: String, sentence: String, trigger: RuleTrigger, at now: Date) throws { try base.edit(id: id, sentence: sentence, trigger: trigger, at: now) }
    func restoreDeleted(_ rule: LearnedRule) throws { try base.restoreDeleted(rule) }
    func delete(id: String) throws { try base.delete(id: id) }
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], at now: Date) throws { try base.recordOutcome(outcome, ruleIDs: ruleIDs, at: now) }
    func recordSignal(_ outcome: RuleOutcome, source: RuleOutcomeSource, ruleIDs: [String], eventID: String, at: Date) throws {}
    func recordAction(_ action: RuleActionRecord) throws { ruleActions.append(action) }
    func resolveAction(id: String, state: RuleActionRecord.State, at: Date) throws {}
    func declineRule(id: String, at: Date) throws { try base.setStatus(.retired, id: id, at: at) }
    func noteMatches(ids: [String], at: Date) throws {}
    func advanceOutcomes(at: Date) throws {}
}
@MainActor struct LM2DRulesTests {
    @Test func whyUsesOnlyThisRulesOutcomesNewestFirstAndSpendAlwaysAsks() throws {
        let store = LM2DManagedRules(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let rule = try #require(try store.propose([.init(sentence: "Buy coffee", trigger: .init(kind: "spend"), kind: .acts)], at: now).first)
        let model = RulesPaneModel(store: store, journal: JournalViewerModel(journal: LM2JournalFake()))
        #expect(RulesPaneModel.alwaysAsks(rule)); #expect(model.outcomes(for: rule).isEmpty)
        for (index, outcome) in [RuleOutcome.accepted, .undone, .skipped, .ignored, .stale].enumerated() {
            store.outcomeEvents.append(.init(id: "event-\(index)", ruleID: rule.id, at: now.addingTimeInterval(Double(index)), outcome: outcome, source: .explicit, delta: -0.1))
        }
        store.outcomeEvents.append(.init(id: "foreign", ruleID: "other", at: now.addingTimeInterval(99), outcome: .accepted, source: .explicit, delta: 0.1))
        #expect(model.outcomes(for: rule).map(\.outcome) == [.stale, .ignored, .skipped, .undone, .accepted])
        #expect(model.outcomes(for: rule).allSatisfy { !RulesPaneModel.outcomeLabel($0.outcome).isEmpty })
        #expect(model.shadowCaption(rule) == "Seen once. Zeus didn't act.")
        try store.recordAction(.init(id: "shadow", ruleID: rule.id, sessionKey: "synthetic", text: "would have bought coffee for €14", undo: nil, created: now, kind: .shadow))
        #expect(model.shadowCaption(rule) == "Seen once: would have bought coffee for €14")
        model.dismiss(rule); #expect(store.rules.first?.status == .retired)
        model.autonomy = 1; #expect(store.autonomy == 1)
        model.autonomy = 0; #expect(store.autonomy == 0)
        model.autonomy = 0.5; #expect(store.autonomy == 0.5)
    }
}
