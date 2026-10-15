import Foundation
import Observation
import CryptoKit
import ZeusProtocol

/// Atomic encrypted rule state; user consent and confidence survive a restart.
@MainActor @Observable final class PersistentRulesStore: RulesStore, LearningRuleTracking, LearningRuleOutcomeSource, RuleLifecycleStoring {
    struct State: Codable {
        var rules: [LearnedRule] = []
        var autonomy = 0.5
        var outcomeIDs: Set<String> = []
        var shownShadowIDs: Set<String> = []
        var cardRules: [String: [String]] = [:]
        var batches: [[String]] = []
        var outcomes: [RuleOutcomeEvent] = []
        var suppressions: [RuleSuppression] = []
        var actions: [RuleActionRecord] = []
        var lastMatches: [String: Date] = [:]
        var staleThrough: [String: Date] = [:]
        var proposals: [Date] = []
        init() {}
        private enum CodingKeys: String, CodingKey { case rules, autonomy, outcomeIDs, shownShadowIDs, cardRules, batches, outcomes, suppressions, actions, lastMatches, staleThrough, proposals }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rules = try c.decodeIfPresent([LearnedRule].self, forKey: .rules) ?? []
            autonomy = try c.decodeIfPresent(Double.self, forKey: .autonomy) ?? 0.5
            outcomeIDs = try c.decodeIfPresent(Set<String>.self, forKey: .outcomeIDs) ?? []
            shownShadowIDs = try c.decodeIfPresent(Set<String>.self, forKey: .shownShadowIDs) ?? []
            cardRules = try c.decodeIfPresent([String: [String]].self, forKey: .cardRules) ?? [:]
            batches = try c.decodeIfPresent([[String]].self, forKey: .batches) ?? rules.map { [$0.id] }
            outcomes = try c.decodeIfPresent([RuleOutcomeEvent].self, forKey: .outcomes) ?? []
            suppressions = try c.decodeIfPresent([RuleSuppression].self, forKey: .suppressions) ?? []
            actions = try c.decodeIfPresent([RuleActionRecord].self, forKey: .actions) ?? []
            lastMatches = try c.decodeIfPresent([String: Date].self, forKey: .lastMatches) ?? [:]
            staleThrough = try c.decodeIfPresent([String: Date].self, forKey: .staleThrough) ?? [:]
            proposals = try c.decodeIfPresent([Date].self, forKey: .proposals) ?? rules.filter { ($0.author ?? $0.updatedBy) == .agent }.map(\.created)
        }
    }
    @ObservationIgnored var onRuleOutcome: ((RuleOutcome, [String], String, Date) -> Void)?
    private(set) var rules: [LearnedRule]
    private(set) var revision: UInt64 = 0
    private(set) var lastError: String?
    var autonomy: Double {
        get { _ = revision; return state.autonomy }
        set {
            guard newValue.isFinite else { return }
            var next = state; next.autonomy = min(1, max(0, newValue))
            do { try commit(next) } catch { /* Observable lastError is the nonthrowing setter's error channel. */ }
        }
    }
    @ObservationIgnored var state: State
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let keyProvider: any JournalKeyProviding
    init(fileURL: URL = ZeusPaths.appSupport.appendingPathComponent("Rules/rules.zrules"),
         keyProvider: any JournalKeyProviding = KeychainJournalKeyProvider(account: "rules-v1")) throws {
        self.fileURL = fileURL; self.keyProvider = keyProvider
        let loaded = try LearningEncryption.read(State.self, at: fileURL, key: keyProvider) ?? State()
        state = loaded; rules = loaded.rules
    }
    func propose(_ proposals: [RuleProposal], at now: Date) throws -> [LearnedRule] {
        try create(proposals, author: .agent, at: now)
    }
    func addOwn(_ proposal: RuleProposal, at now: Date) throws -> LearnedRule {
        var own = proposal; own.kind = .passive; own.confidence = 0.75
        guard let result = try create([own], author: .user, at: now).first else { throw LearningStorageError.invalidRule }
        return result
    }
    private func create(_ proposals: [RuleProposal], author: RuleAuthor, at now: Date) throws -> [LearnedRule] {
        guard !proposals.isEmpty, proposals.count <= 20, state.rules.count + proposals.count <= 500 else { throw LearningStorageError.invalidRule }
        for proposal in proposals {
            try Self.validate(proposal)
            if author == .agent, state.suppressions.contains(where: { $0.until > now && $0.fingerprint == Self.fingerprint(proposal.sentence, trigger: proposal.trigger) }) {
                throw ToolArgumentError("The user turned off, retired or deleted this rule. Do not propose it again for 30 days.")
            }
        }
        if author == .agent {
            guard state.proposals.filter({ Calendar.current.isDate($0, inSameDayAs: now) }).count + proposals.count <= 3 else {
                throw ToolArgumentError("Propose at most three new rules per day.")
            }
        }
        let created = proposals.map { proposal in
            LearnedRule(id: "rule_" + UUID().uuidString, sentence: proposal.sentence.trimmingCharacters(in: .whitespacesAndNewlines),
                trigger: proposal.trigger, kind: proposal.kind,
                status: author == .user ? .active : (state.autonomy == 0 ? .proposed : (proposal.kind == .acts || proposal.trigger.kind == "spend" ? .shadow : .active)),
                confidence: author == .user ? 0.75 : min(0.7, max(0.4, proposal.confidence)), evidence: proposal.evidence, created: now, updated: now, updatedBy: author, author: author)
        }
        var next = state; next.rules += created; next.batches.append(created.map(\.id))
        if author == .agent { next.proposals = next.proposals.filter { now.timeIntervalSince($0) < 31 * 86400 } + created.map(\.created) }
        try commit(next); return created
    }
    /// A UI toggle/approval is a single durable outcome, never a second recordOutcome call.
    func setStatus(_ status: LearnedRuleStatus, id: String, at now: Date) throws {
        guard let rule = state.rules.first(where: { $0.id == id }) else { throw LearningStorageError.missingRule }
        guard rule.status != status else { return }
        if rule.status == .shadow && (status == .proposed || status == .retired) { try declineRule(id: id, at: now); return }
        var next = state
        let outcome: RuleOutcome = status == .retired || status == .proposed ? .toggledOff : (rule.status == .shadow && status == .active ? .accepted : .toggledOn)
        applySignal(&next, outcome, source: .explicit, ids: [id], eventID: "toggle:" + UUID().uuidString, at: now)
        guard let i = next.rules.firstIndex(where: { $0.id == id }) else { return }
        let needsShadow = rule.kind == .acts || rule.trigger.kind == "spend"
        next.rules[i].status = status
        if status == .active && needsShadow && (!next.shownShadowIDs.contains(id) || rule.status == .retired || rule.trigger.kind == "spend") { next.rules[i].status = .shadow }
        if rule.status == .retired && (status == .active || status == .shadow) {
            next.rules[i].confidence = 0.5; next.staleThrough[id] = now
            for j in next.actions.indices where next.actions[j].ruleID == id && next.actions[j].kind == .shadow && next.actions[j].amount == nil {
                next.actions[j].state = .pending; next.actions[j].created = now
            }
        }
        if (status == .proposed || status == .retired) && next.rules[i].confidence < 0.2 && (rule.author ?? rule.updatedBy) == .agent { next.rules[i].status = .retired }
        next.rules[i].updatedBy = .user
        for j in next.actions.indices where next.actions[j].ruleID == id && next.actions[j].kind == .shadow {
            if next.rules[i].status == .active { next.actions[j].state = .approved }
            else if next.rules[i].status == .proposed || next.rules[i].status == .retired { next.actions[j].state = .off }
        }
        try commit(next)
    }
    func edit(id: String, sentence: String, trigger: RuleTrigger, at now: Date) throws {
        var next = state
        guard let index = next.rules.firstIndex(where: { $0.id == id }) else { throw LearningStorageError.missingRule }
        try Self.validate(.init(sentence: sentence, trigger: trigger))
        next.rules[index].sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        next.rules[index].trigger = trigger; next.rules[index].updated = now; next.rules[index].updatedBy = .user
        next.rules[index].author = .user
        applySignal(&next, .edited, source: .explicit, ids: [id], eventID: "edit:" + UUID().uuidString, at: now)
        try commit(next)
    }
    func restoreDeleted(_ rule: LearnedRule) throws {
        guard !state.rules.contains(where: { $0.id == rule.id }), state.rules.count < 500 else { throw LearningStorageError.invalidRule }
        try Self.validate(.init(sentence: rule.sentence, trigger: rule.trigger, kind: rule.kind, confidence: rule.confidence, evidence: rule.evidence))
        var next = state; next.rules.append(rule)
        next.suppressions.removeAll { $0.reason == "deleted" && $0.fingerprint == Self.fingerprint(rule.sentence, trigger: rule.trigger) }; try commit(next)
    }
    func delete(id: String) throws {
        var next = state
        if let rule = next.rules.first(where: { $0.id == id }) { suppress(&next, rule: rule, reason: "deleted", at: Date()) }
        next.rules.removeAll { $0.id == id }; try commit(next)
    }
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], at now: Date) throws {
        try recordOutcome(outcome, ruleIDs: ruleIDs, eventID: UUID().uuidString, at: now)
    }
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], eventID: String, at now: Date) throws {
        try recordSignal(outcome, source: .explicit, ruleIDs: ruleIDs, eventID: eventID, at: now)
    }
    func associate(cardID: String, ruleIDs: [String]) throws {
        var next = state; next.cardRules[cardID] = ruleIDs; try commit(next)
    }
    func associatedRuleIDs(cardID: String) -> [String] { state.cardRules[cardID] ?? [] }
    func ruleNoticeGroups() -> [[String]] { state.batches }
    func hasShadowShown(id: String) -> Bool { state.shownShadowIDs.contains(id) }
    func undoShadowApproval(id: String, at now: Date) throws {
        var next = state
        guard let i = next.rules.firstIndex(where: { $0.id == id }), next.rules[i].kind == .acts,
              next.rules[i].status == .active else { throw LearningStorageError.missingRule }
        next.rules[i].status = .shadow; next.rules[i].updated = now; next.rules[i].updatedBy = .user
        applySignal(&next, .undone, source: .explicit, ids: [id], eventID: "undo-approval:" + UUID().uuidString, at: now)
        for j in next.actions.indices where next.actions[j].ruleID == id && next.actions[j].kind == .shadow { next.actions[j].state = .pending }
        try commit(next)
    }
    func markShadowShown(id: String) throws -> Bool {
        guard !state.shownShadowIDs.contains(id) else { return false }
        var next = state; next.shownShadowIDs.insert(id); try commit(next); return true
    }
    static func validate(_ proposal: RuleProposal) throws {
        guard proposal.trigger.kind == nil || proposal.trigger.kind == "spend" else { throw LearningStorageError.invalidRule }
        let text = proposal.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, proposal.confidence.isFinite, (0...1).contains(proposal.confidence),
              proposal.evidence.count <= 100, Set(proposal.evidence).count == proposal.evidence.count,
              proposal.evidence.allSatisfy({ !$0.isEmpty && $0.count <= 200 }),
              proposal.trigger.apps.count <= 100, proposal.trigger.apps.allSatisfy(EncryptedJournalStore.isBundleID),
              proposal.trigger.state.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 }) ?? true
        else { throw LearningStorageError.invalidRule }
        if let time = proposal.trigger.time {
            guard (0..<1440).contains(time.startMinute), (0..<1440).contains(time.endMinute),
                  time.weekdays.allSatisfy({ (1...7).contains($0) }) else { throw LearningStorageError.invalidRule }
        }
    }
    func commit(_ next: State) throws {
        do {
            try LearningEncryption.write(next, to: fileURL, key: keyProvider)
            let previous = Set(state.outcomes.map(\.id))
            state = next; rules = next.rules; revision &+= 1; lastError = nil
            for event in next.outcomes where !previous.contains(event.id) { onRuleOutcome?(event.outcome, [event.ruleID], event.id, event.at) }
        } catch { lastError = "Zeus couldn't save your rules. Your previous rules are unchanged."; throw error }
    }
}
