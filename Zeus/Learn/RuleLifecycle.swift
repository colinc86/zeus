import Foundation
import CryptoKit

extension PersistentRulesStore {
    var outcomeEvents: [RuleOutcomeEvent] { _ = revision; return state.outcomes }
    var suppressedRules: [RuleSuppression] { _ = revision; return state.suppressions }
    var ruleActions: [RuleActionRecord] { _ = revision; return state.actions }
    static func fingerprint(_ sentence: String, trigger: RuleTrigger) -> String {
        let words = sentence.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).sorted().joined(separator: " ")
        // Set order must not affect a fingerprint.
        let triggerText = [trigger.kind ?? "", trigger.state ?? "", trigger.apps.sorted().joined(separator: ","),
                           trigger.time.map { "\($0.startMinute):\($0.endMinute):\($0.weekdays.sorted())" } ?? ""].joined(separator: "|")
        return SHA256.hash(data: Data((words + "|" + triggerText).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func suppress(_ next: inout State, rule: LearnedRule, reason: String, at now: Date) {
        let fingerprint = Self.fingerprint(rule.sentence, trigger: rule.trigger)
        next.suppressions.removeAll { $0.fingerprint == fingerprint || $0.until <= now }
        next.suppressions.append(.init(fingerprint: fingerprint, sentence: rule.sentence, trigger: rule.trigger,
                                       until: now.addingTimeInterval(30 * 86400), reason: reason))
    }
    func recordSignal(_ outcome: RuleOutcome, source: RuleOutcomeSource, ruleIDs: [String], eventID: String, at now: Date) throws {
        guard !eventID.isEmpty, eventID.count <= 400, now.timeIntervalSince1970.isFinite else { throw LearningStorageError.invalidRule }
        var next = state
        applySignal(&next, outcome, source: source, ids: ruleIDs, eventID: eventID, at: now)
        guard next.outcomeIDs != state.outcomeIDs else { return }
        try commit(next)
    }
    func applySignal(_ next: inout State, _ outcome: RuleOutcome, source: RuleOutcomeSource, ids: [String], eventID: String, at now: Date) {
        for i in next.rules.indices where ids.contains(next.rules[i].id) {
            let id = eventID + ":" + next.rules[i].id
            guard !next.outcomeIDs.contains(id), !next.outcomeIDs.contains(eventID) else { continue }
            if source == .heldRead && next.outcomes.contains(where: { $0.ruleID == next.rules[i].id && $0.source == .heldRead && Calendar.current.isDate($0.at, inSameDayAs: now) }) { continue }
            let delta: Double = switch outcome {
            case .accepted: source == .actedUnchanged ? 0.03 : (source == .heldRead ? 0.02 : 0.10)
            case .undone: source == .holdShown ? -0.10 : -0.30
            case .skipped: source == .shadowDeclined ? -0.20 : -0.10
            case .ignored: -0.05
            case .toggledOff: -0.30
            case .toggledOn: 0.10
            case .edited: max(0, 0.60 - next.rules[i].confidence)
            case .stale: -0.10
            }
            next.rules[i].confidence = min(1, max(0, ((next.rules[i].confidence + delta) * 1_000_000).rounded() / 1_000_000)); next.rules[i].updated = now
            if outcome == .edited { next.rules[i].updatedBy = .user; next.rules[i].author = .user }
            if next.rules[i].confidence < 0.2 && (next.rules[i].author ?? next.rules[i].updatedBy) == .agent { next.rules[i].status = .retired }
            next.outcomes.append(.init(id: id, ruleID: next.rules[i].id, at: now, outcome: outcome, source: source, delta: delta))
            next.outcomeIDs.insert(id)
            if outcome == .toggledOff || next.rules[i].status == .retired {
                let rule = next.rules[i]; suppress(&next, rule: rule, reason: outcome.rawValue, at: now)
            }
        }
    }
    func recordAction(_ action: RuleActionRecord) throws {
        guard state.actions.count < 10_000, !action.id.isEmpty, action.id.count <= 200,
              !action.text.isEmpty, action.text.count <= 1000, (action.undo?.count ?? 0) <= 1000,
              state.rules.contains(where: { $0.id == action.ruleID }) else { throw LearningStorageError.invalidRule }
        if let old = state.actions.first(where: { $0.id == action.id }) {
            guard old == action else { throw LearningStorageError.invalidRule }; return
        }
        var next = state; next.actions.append(action)
        if action.kind == .shadow { next.shownShadowIDs.insert(action.ruleID) }
        try commit(next)
    }
    func resolveAction(id: String, state newState: RuleActionRecord.State, at now: Date) throws {
        guard let action = state.actions.first(where: { $0.id == id }) else { throw LearningStorageError.missingRule }
        if action.state == newState { return }
        guard action.state == .pending || action.state == .ignored || (action.state == .settled && newState == .undoRequested) else { throw LearningStorageError.invalidRule }
        if action.kind == .shadow && newState == .approved && action.amount == nil { try setStatus(.active, id: action.ruleID, at: now); return }
        if action.kind == .shadow && newState == .declined { try declineRule(id: action.ruleID, at: now); return }
        var next = state
        guard let i = next.actions.firstIndex(where: { $0.id == id }) else { return }
        next.actions[i].state = newState
        if newState == .undoRequested { applySignal(&next, .undone, source: .explicit, ids: [action.ruleID], eventID: "undo:" + id, at: now) }
        if newState == .off {
            applySignal(&next, .toggledOff, source: .explicit, ids: [action.ruleID], eventID: "off:" + id, at: now)
            if let r = next.rules.firstIndex(where: { $0.id == action.ruleID }), next.rules[r].status != .retired { next.rules[r].status = .proposed }
        }
        try commit(next)
    }
    func declineRule(id: String, at now: Date) throws {
        guard state.rules.contains(where: { $0.id == id }) else { throw LearningStorageError.missingRule }
        var next = state
        applySignal(&next, .skipped, source: .shadowDeclined, ids: [id], eventID: "decline:" + id, at: now)
        guard let i = next.rules.firstIndex(where: { $0.id == id }) else { return }
        next.rules[i].status = .retired; next.rules[i].updatedBy = .user
        let rule = next.rules[i]; suppress(&next, rule: rule, reason: "declined", at: now)
        for j in next.actions.indices where next.actions[j].ruleID == id && next.actions[j].kind == .shadow { next.actions[j].state = .declined }
        try commit(next)
    }
    func noteMatches(ids: [String], at now: Date) throws {
        var next = state
        // Checkpoint at most hourly while a trigger remains true; the grace below prevents early staleness.
        for id in ids where now.timeIntervalSince(next.lastMatches[id] ?? .distantPast) >= 3600 { next.lastMatches[id] = now }
        if next.lastMatches != state.lastMatches { try commit(next) }
    }
    var nextOutcomeBoundary: Date? {
        let actions = state.actions.filter { $0.state == .pending }.map { $0.created.addingTimeInterval(86400) }
        let stale = state.rules.filter { $0.trigger.isEvaluable && $0.status != .retired }.map {
            max(state.lastMatches[$0.id]?.addingTimeInterval(3600) ?? $0.created, state.staleThrough[$0.id] ?? $0.created).addingTimeInterval(30 * 86400)
        }
        return (actions + stale).min()
    }
    func advanceOutcomes(at now: Date) throws {
        var next = state
        for i in next.actions.indices where next.actions[i].state == .pending && next.actions[i].created.addingTimeInterval(86400) <= now {
            let action = next.actions[i]
            applySignal(&next, action.kind == .acted ? .accepted : .ignored,
                        source: action.kind == .acted ? .actedUnchanged : .shadowIgnored, ids: [action.ruleID], eventID: "elapsed:" + action.id, at: now)
            next.actions[i].state = action.kind == .acted ? .settled : .ignored
        }
        for rule in next.rules where rule.trigger.isEvaluable && rule.status != .retired {
            var through = max(next.lastMatches[rule.id]?.addingTimeInterval(3600) ?? rule.created, next.staleThrough[rule.id] ?? rule.created)
            while through.addingTimeInterval(30 * 86400) <= now {
                through = through.addingTimeInterval(30 * 86400)
                applySignal(&next, .stale, source: .stale, ids: [rule.id], eventID: "stale:\(rule.id):\(through.timeIntervalSince1970)", at: through)
                next.staleThrough[rule.id] = through
                if next.rules.first(where: { $0.id == rule.id })?.status == .retired { break }
            }
        }
        guard next.outcomeIDs != state.outcomeIDs else { return }
        try commit(next)
    }
}

extension RuleActionRecord {
    /// Standing approval requires a real pending dry run; purchases always use their own question.
    func isEligibleShadowResult(for rule: LearnedRule) -> Bool {
        rule.status == .shadow && rule.kind == .acts && rule.trigger.kind != "spend"
            && ruleID == rule.id && kind == .shadow && amount == nil && approvalCardID == nil
            && (state == .pending || state == .ignored)
    }
}
