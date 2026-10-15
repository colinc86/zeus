import Foundation
import ZeusProtocol

extension ZeusRuntime {
    /// Presentation only: retain original action text for exact purchase approval matching.
    static func shadowActionText(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["would have", "would've", "would’ve", "I'd have", "I’d have", "I would have"] {
            guard text.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let rest = text.dropFirst(prefix.count)
            if rest.first?.isWhitespace == true {
                let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return text
    }
    static func formattedRuleAmount(_ amount: Double, currency: String, locale: Locale = .autoupdatingCurrent) -> String {
        amount.formatted(FloatingPointFormatStyle<Double>.Currency(code: currency)
            .precision(.fractionLength(amount.rounded() == amount ? 0 : 2)).locale(locale))
    }
    static let ruleSpendPrefix = "zeus_rule_spend_"
    func callRuleActionTool(_ name: String, args: ToolArguments, sessionKey: String) async throws -> ToolResult {
        guard let store = learningRules as? any RuleLifecycleStoring, let redactor = learningRedactor else { throw ToolArgumentError("Rule actions aren't available.") }
        guard (store as? any LearningStorageRecovering)?.storageWaitingForUnlock != true else {
            throw ToolArgumentError("Learning storage is locked. Wait for it to unlock before acting on a rule.")
        }
        let id = try args.requiredString("ruleID")
        guard let original = store.rules.first(where: { $0.id == id }) else { throw ToolArgumentError("That rule no longer exists.") }
        let rawText = try args.requiredString(name == "zeus_rule_shadow" ? "wouldHave" : "did"), rawUndo = try args.string("undo")
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rawText.count <= 1000, (rawUndo?.count ?? 0) <= 1000 else { throw ToolArgumentError("Use a short action description and undo instruction (at most 1000 characters each).") }
        let token = generation, session = sessions.first { $0.sessionKey == sessionKey }?.id
        let safe = await redactor.redact(.init(description: rawText, text: rawUndo))
        guard running, generation == token, isAdmitted(sessionKey), session != nil, sessions.first(where: { $0.sessionKey == sessionKey })?.id == session,
              let rule = store.rules.first(where: { $0.id == id }), rule == original else { throw ToolArgumentError("The rule or assistant changed while preparing this action. Read the rules again.") }
        guard !rule.trigger.isEvaluable || rule.trigger.matches(learningContext(), at: clock.now, calendar: learningCalendar) else { throw ToolArgumentError("This rule's trigger has not matched. Do not act.") }
        let spend = rule.trigger.kind == "spend"
        if name == "zeus_rule_shadow" {
            guard rule.status == .shadow || (spend && rule.status == .active) else { throw ToolArgumentError("Only a shadow rule can report a shadow result.") }
            if let old = store.ruleActions.first(where: { $0.ruleID == id && $0.kind == .shadow && (!spend || $0.state == .pending || $0.state == .ignored) }) {
                reconnectPhaseDNotices()
                return result(["action_id": .string(old.id), "approvalID": .string(old.id), "status": .string(old.state.rawValue), "act": false])
            }
            var action = RuleActionRecord(id: "rule_action_" + UUID().uuidString, ruleID: id, sessionKey: sessionKey,
                text: safe.value.description, undo: nil, created: clock.now, kind: .shadow)
            if spend {
                guard let amount = try args.number("amount"), amount > 0, amount <= 1_000_000_000,
                      let currency = try args.string("currency"), currency.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
                    throw ToolArgumentError("Every purchase needs its amount and three-letter currency, for example amount=14, currency=EUR. Wait for this purchase's answer.")
                }
                action.amount = amount; action.currency = currency; action.approvalCardID = Self.ruleSpendPrefix + UUID().uuidString
            }
            try store.recordAction(action)
            reconnectPhaseDNotices(); learningContextDidChange(); try checkCardPersistence()
            return result(["action_id": .string(action.id), "approvalID": .string(action.id), "act": false,
                "note": .string(spend ? "Wait for the amount-bearing purchase question to be answered. Approval applies only to this exact purchase." : "Shadow is not permission. Wait for approval, then read the rules again.")])
        }
        guard rule.status == .active || (spend && rule.status == .shadow) else { throw ToolArgumentError("This rule isn't active. Do not act under it.") }
        var approval: RuleActionRecord?
        if spend {
            let approvalID = try args.requiredString("approvalID")
            approval = store.ruleActions.first { $0.id == approvalID && $0.ruleID == id && $0.sessionKey == sessionKey && $0.kind == .shadow }
            guard let approved = approval, approved.state == .approved, approved.text == safe.value.description,
                  clock.now.timeIntervalSince(approved.created) <= 3600,
                  !store.ruleActions.contains(where: { $0.kind == .acted && $0.approvalCardID == approved.approvalCardID }) else {
                throw ToolArgumentError("This exact purchase needs a fresh affirmative answer with its amount. Each approval is single-use; a higher amount always needs another question.")
            }
        }
        let action = RuleActionRecord(id: "rule_action_" + UUID().uuidString, ruleID: id, sessionKey: sessionKey,
            text: safe.value.description, undo: safe.value.text, created: clock.now, kind: .acted,
            approvalCardID: approval?.approvalCardID, amount: approval?.amount, currency: approval?.currency)
        try store.recordAction(action); reconnectPhaseDNotices(); learningContextDidChange()
        return result(["action_id": .string(action.id), "ok": true])
    }
    func recordSpendAnswer(_ card: Card, response: CardResponse) -> Bool {
        guard let store = learningRules as? any RuleLifecycleStoring,
              let action = store.ruleActions.first(where: { $0.approvalCardID == card.id && $0.kind == .shadow }) else { return false }
        do { try store.resolveAction(id: action.id, state: response.optionID == "approve" && !response.skipped ? .approved : .declined, at: clock.now) }
        catch { learningError = "Zeus couldn't save this purchase decision." }
        reconnectPhaseDNotices(); return true
    }
    func reconnectPhaseDNotices() {
        guard let store = learningRules as? any RuleLifecycleStoring, let recorder = cards as? any LearningNoticeRecording else { return }
        for action in store.ruleActions.suffix(200) {
            guard let rule = store.rules.first(where: { $0.id == action.ruleID }) else { continue }
            if let cardID = action.approvalCardID, action.kind == .shadow, action.state == .pending || action.state == .ignored,
               let response = cards.card(id: cardID)?.response {
                do { try store.resolveAction(id: action.id, state: response.optionID == "approve" && !response.skipped ? .approved : .declined, at: response.respondedAt) }
                catch { learningError = "Zeus couldn't recover this purchase decision." }
                continue
            }
            if let cardID = action.approvalCardID, action.kind == .shadow, action.state == .pending, cards.card(id: cardID) == nil {
                do { try responseJournal?.prepare(cardID) } catch { learningError = "Zeus couldn't prepare this purchase question."; continue }
                appQuestionIDs.insert(cardID)
                // Durable action comes first: rebuilding after a crash presents the same approval exactly once.
                cards.add(Card(id: cardID, kind: .question, title: "Approve this purchase?",
                    body: action.text + " — " + Self.formattedRuleAmount(action.amount ?? 0, currency: action.currency ?? ""),
                    options: [.init(id: "approve", label: "Approve this purchase"), .init(id: "decline", label: "Not this")],
                    priority: .high, sessionKey: action.sessionKey, createdAt: action.created, updatedAt: action.created))
            }
            let shadow = action.kind == .shadow
            var summary: String, title: String?, secondary: String?
            switch action.state {
            case .declined: summary = "Got it. I won't."; title = nil
            case .off: summary = "Rule turned off"; title = "Review"
            case .undoRequested: summary = "Undoing…"; title = nil
            case .approved: summary = action.amount == nil ? "OK. I'll do that from now on." : "Approved this purchase only."; title = action.amount == nil ? "Undo" : nil
            default:
                if shadow && rule.status == .retired { summary = "Retired: “\(rule.sentence)”"; title = "Review" }
                else if shadow && rule.status == .active && action.amount == nil { summary = "OK. I'll do that from now on."; title = "Undo" }
                else {
                    summary = shadow ? "I'd have \(Self.shadowActionText(action.text))" : "Did: \(action.text)"
                    if let amount = action.amount, let currency = action.currency { summary += " — \(Self.formattedRuleAmount(amount, currency: currency))" }
                    title = shadow ? (action.amount == nil ? "OK next time?" : nil) : (action.undo == nil ? "Not again" : "Undo")
                    secondary = shadow && action.amount == nil ? "Not this" : nil
                }
            }
            let notice = LearningNotice(id: "action:" + action.id, kind: .shadow, createdAt: action.created,
                summary: summary, actionTitle: title, detail: "Your rule: " + rule.sentence, ruleID: rule.id)
            var primaryAction: (@MainActor () -> Void)?, secondaryAction: (@MainActor () -> Void)?
            if let title { primaryAction = { [weak self] in self?.performRuleNotice(actionID: action.id, title: title) } }
            if secondary != nil { secondaryAction = { [weak self] in self?.performRuleNotice(actionID: action.id, title: "Not this") } }
            recorder.recordLearningNotice(notice, action: primaryAction, secondaryTitle: secondary, secondary: secondaryAction)
        }
        for rule in store.rules where rule.status == .retired {
            if store.ruleActions.contains(where: { $0.ruleID == rule.id && $0.state == .declined }) { continue }
            let recent = store.outcomeEvents.filter { $0.ruleID == rule.id && clock.now.timeIntervalSince($0.at) <= 30 * 86400 }
            let counts = Dictionary(grouping: recent, by: \.outcome).mapValues(\.count)
            let reason = (counts[.stale] ?? 0) > (counts[.toggledOff] ?? 0) && (counts[.stale] ?? 0) > (counts[.skipped] ?? 0) + (counts[.undone] ?? 0) ? "that never applied" : ((counts[.toggledOff] ?? 0) > (counts[.skipped] ?? 0) + (counts[.undone] ?? 0) ? "you turned off" : "you kept skipping")
            recorder.recordLearningNotice(.init(id: "retired:" + rule.id, kind: .newRule, createdAt: rule.updated,
                summary: "Retired a rule \(reason): “\(rule.sentence)”", actionTitle: "Review", detail: nil, ruleID: rule.id),
                action: { [weak self] in self?.onReviewRule?(rule.id) })
        }
    }
    private func performRuleNotice(actionID: String, title: String) {
        guard let store = learningRules as? any RuleLifecycleStoring, let action = store.ruleActions.first(where: { $0.id == actionID }),
              let rule = store.rules.first(where: { $0.id == action.ruleID }) else { return }
        do {
            if title == "Review" { onReviewRule?(rule.id); return }
            if title == "Not this" { try store.declineRule(id: rule.id, at: clock.now) }
            else if title == "OK next time?" { try store.resolveAction(id: action.id, state: .approved, at: clock.now) }
            else if title == "Not again" { try store.resolveAction(id: action.id, state: .off, at: clock.now) }
            else if title == "Undo", action.kind == .shadow { try (store as? any LearningRuleTracking)?.undoShadowApproval(id: rule.id, at: clock.now) }
            else if title == "Undo", action.kind == .acted, let undo = action.undo, action.state != .undoRequested {
                guard let ledger else { throw LearningStorageError.invalidRule }
                let id = "undo_" + action.id
                if ledger.record(id: id) == nil {
                    var delivery = Delivery(id: id, kind: .userMessage, sessionKey: action.sessionKey,
                        content: "The user pressed Undo. Reverse what you did for the rule “\(rule.sentence)”: \(action.text). \(undo) Say plainly if it cannot be reversed.", createdAt: clock.now)
                    delivery.meta = ["kind": "ruleUndo", "delivery_id": id]
                    try ledger.insert(.init(delivery: delivery))
                }
                try store.resolveAction(id: action.id, state: .undoRequested, at: clock.now)
                _ = beginSend(id: id)
            }
            learningContextDidChange()
        } catch { learningError = "Zeus couldn't save this rule action. Try again." }
    }
}
