import Foundation
import Observation
import ZeusProtocol

/// Atomic encrypted rule state; user consent and confidence survive a restart.
@MainActor @Observable final class PersistentRulesStore: RulesStore {
    private struct State: Codable {
        var rules: [LearnedRule] = []
        var autonomy = 0.5
        var outcomeIDs: Set<String> = []
        var shownShadowIDs: Set<String> = []
    }
    private(set) var rules: [LearnedRule]
    private(set) var revision: UInt64 = 0
    private(set) var lastError: String?
    var autonomy: Double {
        get { state.autonomy }
        set {
            guard newValue.isFinite else { return }
            var next = state; next.autonomy = min(1, max(0, newValue))
            do { try commit(next) } catch { /* Observable lastError is the nonthrowing setter's error channel. */ }
        }
    }
    @ObservationIgnored private var state: State
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
        for proposal in proposals { try Self.validate(proposal) }
        let created = proposals.map { proposal in
            LearnedRule(id: "rule_" + UUID().uuidString, sentence: proposal.sentence.trimmingCharacters(in: .whitespacesAndNewlines),
                trigger: proposal.trigger, kind: proposal.kind,
                status: proposal.confidence < 0.2 ? .retired : (author == .user ? .active : (state.autonomy == 0 ? .proposed : (proposal.kind == .acts ? .shadow : .active))),
                confidence: proposal.confidence, evidence: proposal.evidence, created: now, updated: now, updatedBy: author)
        }
        var next = state; next.rules += created; try commit(next); return created
    }
    /// A UI toggle is one atomic status/confidence mutation. Do not separately report toggledOn/Off.
    func setStatus(_ status: LearnedRuleStatus, id: String, at now: Date) throws {
        var next = state
        guard let index = next.rules.firstIndex(where: { $0.id == id }) else { throw LearningStorageError.missingRule }
        guard next.rules[index].status != status else { return }
        next.rules[index].status = status; next.rules[index].updatedBy = .user; next.rules[index].updated = now
        adjust(&next.rules[index], outcome: status == .retired ? .toggledOff : .toggledOn)
        // Explicit user re-enablement is allowed even for a previously retired low-confidence rule.
        if status == .active { next.rules[index].confidence = max(0.2, next.rules[index].confidence); next.rules[index].status = .active }
        try commit(next)
    }
    func edit(id: String, sentence: String, trigger: RuleTrigger, at now: Date) throws {
        var next = state
        guard let index = next.rules.firstIndex(where: { $0.id == id }) else { throw LearningStorageError.missingRule }
        try Self.validate(.init(sentence: sentence, trigger: trigger))
        next.rules[index].sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        next.rules[index].trigger = trigger; next.rules[index].updated = now; next.rules[index].updatedBy = .user
        // User corrections preserve evidence/confidence; edited is an observation, not a rejection.
        try commit(next)
    }
    func restoreDeleted(_ rule: LearnedRule) throws {
        guard !state.rules.contains(where: { $0.id == rule.id }), state.rules.count < 500 else { throw LearningStorageError.invalidRule }
        try Self.validate(.init(sentence: rule.sentence, trigger: rule.trigger, kind: rule.kind, confidence: rule.confidence, evidence: rule.evidence))
        var next = state; next.rules.append(rule); try commit(next)
    }
    func delete(id: String) throws {
        var next = state; next.rules.removeAll { $0.id == id }; try commit(next)
    }
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], at now: Date) throws {
        try recordOutcome(outcome, ruleIDs: ruleIDs, eventID: UUID().uuidString, at: now)
    }
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], eventID: String, at now: Date) throws {
        guard !state.outcomeIDs.contains(eventID), !ruleIDs.isEmpty else { return }
        var next = state
        for index in next.rules.indices where ruleIDs.contains(next.rules[index].id) {
            adjust(&next.rules[index], outcome: outcome); next.rules[index].updated = now
        }
        next.outcomeIDs.insert(eventID); try commit(next)
    }
    func markShadowShown(id: String) throws -> Bool {
        guard !state.shownShadowIDs.contains(id) else { return false }
        var next = state; next.shownShadowIDs.insert(id); try commit(next); return true
    }
    static func validate(_ proposal: RuleProposal) throws {
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
    private func adjust(_ rule: inout LearnedRule, outcome: RuleOutcome) {
        let delta: Double = switch outcome {
        case .accepted, .toggledOn: 0.05
        case .skipped: -0.15
        case .undone, .toggledOff: -0.25
        case .ignored: -0.1
        case .edited: 0
        }
        rule.confidence = min(1, max(0, rule.confidence + delta))
        if rule.confidence < 0.2 { rule.status = .retired }
    }
    private func commit(_ next: State) throws {
        do {
            try LearningEncryption.write(next, to: fileURL, key: keyProvider)
            state = next; rules = next.rules; revision &+= 1; lastError = nil
        } catch { lastError = "Zeus couldn't save your rules. Your previous rules are unchanged."; throw error }
    }
}

extension RuleTrigger {
    /// No constraint means assistant guidance only, never an indefinite interruption hold.
    var isEvaluable: Bool { time != nil || !apps.isEmpty || state != nil }
    func matches(_ context: LearningContext, at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEvaluable, !context.isLocked, !context.isPrivate else { return false }
        if !apps.isEmpty, !apps.contains(context.frontmostApp ?? "") { return false }
        if let state, !context.states.contains(state) { return false }
        if let time {
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            let wraps = time.startMinute > time.endMinute
            let inside = time.startMinute == time.endMinute || (wraps ? minute >= time.startMinute || minute < time.endMinute : minute >= time.startMinute && minute < time.endMinute)
            guard inside else { return false }
            let weekdayDate = wraps && minute < time.endMinute ? calendar.date(byAdding: .day, value: -1, to: date) ?? date : date
            if !time.weekdays.isEmpty, !time.weekdays.contains(calendar.component(.weekday, from: weekdayDate)) { return false }
        }
        return true
    }
}
