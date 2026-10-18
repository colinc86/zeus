import Foundation
import CryptoKit
import ZeusProtocol

extension ZeusRuntime: ProactiveAssistantControlling {
    static let dailyUnpromptedBudget = 6

    func proactiveDay(_ date: Date) -> String {
        let c = learningCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    var remainingUnpromptedBudget: Int {
        max(0, Self.dailyUnpromptedBudget - (proactiveState?.count(day: proactiveDay(clock.now)) ?? 0))
    }
    var proactiveBudgetLine: String {
        let remaining = remainingUnpromptedBudget
        return remaining == 0
            ? "Unprompted messages left today: 0. Anything more arrives held unless it's high priority."
            : "Unprompted messages left today: \(remaining) (high priority doesn't count)."
    }
    func applyProactiveBudget(_ original: Card) throws -> Card {
        guard original.origin == .unprompted, original.priority != .high else { return original }
        var card = original
        let day = proactiveDay(clock.now)
        if cards.card(id: card.id) == nil {
            if card.muteDecision == nil, remainingUnpromptedBudget == 0 {
                card.muteDecision = .init(ratingID: "budget:" + day, kindLabel: "over today's limit",
                    reason: "over today's limit", engine: "dailyBudget", score: 1, threshold: 1,
                    decidedAt: clock.now, source: .dailyBudget)
            }
            try proactiveState?.record(cardID: card.id, day: day)
        }
        return card
    }
    func showBudgetHeldCard(id: String) throws {
        guard cards.card(id: id)?.muteDecision?.source == .dailyBudget else { return }
        let releasedAt = cards.card(id: id)?.muteDecision?.releasedAt ?? clock.now
        _ = cards.update(id: id) { $0.muteDecision?.releasedAt = releasedAt }
        try checkCardPersistence()
    }

    func noteProactiveActivity(at date: Date) {
        guard running, date <= clock.now, learningCalendar.isDate(date, inSameDayAs: clock.now) else { return }
        proactiveActivityAt = max(proactiveActivityAt ?? .distantPast, date)
        learningContextDidChange()
    }
    func proactiveSettingsDidChange() { learningContextDidChange() }
    var briefEnabled: Bool {
        morningBriefSettings?.effectiveEnabled(managed: managedController.enabled) == true
    }
    var nextBriefBoundary: Date? {
        guard briefEnabled, let settings = morningBriefSettings, settings.schedule == .fixedTime else { return nil }
        let now = clock.now
        let today = learningCalendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: now) ?? now
        return today > now ? today : learningCalendar.date(byAdding: .day, value: 1, to: today)
    }
    func considerMorningBrief() {
        guard briefEnabled, let settings = morningBriefSettings, let ledger,
              !learningContext().isLocked else { return }
        let now = clock.now, day = proactiveDay(now), id = "brief_" + day
        guard ledger.record(id: id) == nil else { return }
        switch settings.schedule {
        case .firstActivity:
            guard let activity = proactiveActivityAt, learningCalendar.isDate(activity, inSameDayAs: now) else { return }
        case .fixedTime:
            let deadline = learningCalendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: now) ?? now
            guard now >= deadline else { return }
        }
        do {
            let levels = morningBriefLevels()
            var evidence: [JournalItem] = []
            if !levels.isEmpty, let journal = learningJournal {
                var query = JournalQuery()
                query.from = learningCalendar.date(byAdding: .day, value: -1, to: learningCalendar.startOfDay(for: now))
                query.to = learningCalendar.startOfDay(for: now); query.levels = levels
                query.kinds = [.activity, .focus, .description, .typedText]; query.limit = 100_000
                evidence = try journal.items(matching: query)
            }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = learningCalendar; formatter.timeZone = learningCalendar.timeZone
            formatter.dateFormat = "EEEE d MMMM"
            let context = levels.isEmpty ? "your Notes/" : "yesterday's summary, your Notes/"
            var content = """
            Start of my day: \(formatter.string(from: now)).
            Using \(context), my rules, and your own tools (calendar, mail, tasks) if you have them, send me one short brief of what matters today: what's coming up, what's at risk, what you've prepared. One zeus_present with about "Morning brief": a short title, then at most 6 lines, the most important first. If nothing matters today, zeus_ack and stay quiet.
            """
            let samples = evidence.suffix(6).compactMap { item -> String? in
                let text = item.level == .typed ? item.payload.value.topic : item.payload.value.description
                guard let text, !text.isEmpty else { return nil }
                return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
            }
            if !samples.isEmpty { content += "\nYesterday (from Zeus's journal, private details removed):\n" + samples.map { "- " + $0 }.joined(separator: "\n") }
            content += "\n" + proactiveBudgetLine
            content = Self.withLearningFiles(content, paths: proactiveRuleFiles)
            var delivery = Delivery(id: id, kind: .brief, sessionKey: assistantTarget ?? "", content: content, createdAt: now)
            delivery.meta = ["kind": "brief", "brief_day": day, "evidence": evidence.map(\.id).joined(separator: ","),
                             "levels": levels.map { String($0.rawValue) }.sorted().joined(separator: ",")]
            try ledger.insert(.init(delivery: delivery, awaitingAssistant: assistantTarget == nil ? true : nil))
            processDueDeliveries()
        } catch { learningError = "Zeus couldn't prepare your morning brief. It will try again." }
    }
    func proactiveDeliveryAllowed(_ delivery: Delivery) -> Bool {
        if delivery.kind == .brief {
            let levels = Set(delivery.meta["levels", default: ""].split(separator: ",").compactMap { Int($0).flatMap(JournalLevel.init(rawValue:)) })
            return briefEnabled && levels.isSubset(of: morningBriefLevels()) && delivery.meta["brief_day"] == proactiveDay(clock.now)
        }
        if delivery.kind == .ruleTrigger {
            guard delivery.meta["window_open"] == "true", let rule = learningRules?.rules.first(where: { $0.id == delivery.meta["rule_id"] }) else { return false }
            return (rule.status == .active || rule.status == .shadow) && rule.status.rawValue == delivery.meta["rule_status"]
                && rule.trigger.matches(learningContext(), at: clock.now, calendar: learningCalendar)
                && triggerWindowKey(rule) == delivery.meta["window_key"]
        }
        return true
    }

    private var proactiveRuleFiles: [String] {
        guard let root = learningFolder?.folderURL else { return [] }
        let path = "Zeus/rules.md", url = root.appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return [] }
        return [path]
    }

    /// The ledger is the window journal too: restarts cannot recreate an open trigger.
    func reconcileProactiveDeliveries(matching: [LearnedRule]) {
        guard let ledger else { return }
        let matching = matching.filter { $0.kind == .acts && $0.trigger.isEvaluable }
        let keys = Dictionary(uniqueKeysWithValues: matching.map { ($0.id, triggerWindowKey($0)) })
        do {
            let staleBriefs = Set(ledger.records.filter { $0.delivery.kind == .brief && $0.isPending && !proactiveDeliveryAllowed($0.delivery) }.map { $0.delivery.id })
            eraseLearningDeliveries(ids: staleBriefs)
            let staleTriggers = Set(ledger.records.filter {
                $0.delivery.kind == .ruleTrigger && $0.isPending && !proactiveDeliveryAllowed($0.delivery)
            }.map { $0.delivery.id })
            eraseLearningDeliveries(ids: staleTriggers)
            let closed = ledger.records.filter {
                $0.delivery.kind == .ruleTrigger && $0.delivery.meta["window_open"] == "true"
                    && keys[$0.delivery.meta["rule_id", default: ""]] != $0.delivery.meta["window_key"]
            }
            for record in closed {
                try ledger.update(id: record.delivery.id) { $0.meta["window_open"] = "false" }
                if record.isPending { eraseLearningDeliveries(ids: [record.delivery.id]) }
            }
            for rule in matching {
                guard let key = keys[rule.id] else { continue }
                let previous = ledger.records.filter { $0.delivery.kind == .ruleTrigger && $0.delivery.meta["rule_id"] == rule.id && $0.delivery.meta["window_key"] == key }
                // A timed window stays consumed even if its app/state dimension briefly stops matching.
                guard !previous.contains(where: { rule.trigger.time != nil || $0.delivery.meta["window_open"] == "true" }) else { continue }
                let id = "trigger_" + UUID().uuidString
                let shadow = rule.status == .shadow
                let status = shadow ? "shadow, waiting for my OK" : "active"
                let instruction = shadow
                    ? "This rule isn't approved yet: call zeus_rule_shadow {ruleID: \"\(rule.id)\", wouldHave} with what you would have done, and don't do it. Then zeus_ack."
                    : "This rule is active: act on it now, then call zeus_rule_acted {ruleID: \"\(rule.id)\", did, undo} right away. If this trigger doesn't call for anything, zeus_ack and stay quiet."
                let content = Self.withLearningFiles("Rule trigger (\(status)): \"\(rule.sentence)\" · rule \(rule.id).\nMatched: \(triggerDescription(rule.trigger)).\n\(instruction)\n\(proactiveBudgetLine)", paths: proactiveRuleFiles)
                var delivery = Delivery(id: id, kind: .ruleTrigger, sessionKey: assistantTarget ?? "", content: content, createdAt: clock.now)
                delivery.meta = ["kind": "ruleTrigger", "rule_id": rule.id, "window_key": key, "window_open": "true", "rule_status": rule.status.rawValue, "rule_sentence": rule.sentence,
                                 "evidence": rule.evidence.joined(separator: ",")]
                try ledger.insert(.init(delivery: delivery, awaitingAssistant: assistantTarget == nil ? true : nil))
            }
            processDueDeliveries()
        } catch { learningError = "Zeus couldn't save a rule trigger. It will try again." }
    }
    private func triggerWindowKey(_ rule: LearnedRule) -> String {
        var day = clock.now
        if let time = rule.trigger.time, time.startMinute > time.endMinute,
           learningCalendar.component(.hour, from: day) * 60 + learningCalendar.component(.minute, from: day) < time.endMinute {
            day = learningCalendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        let time = rule.trigger.time
        let parts = [rule.sentence, rule.trigger.apps.sorted().joined(separator: ","), rule.trigger.state ?? "",
                     String(time?.startMinute ?? -1), String(time?.endMinute ?? -1),
                     time?.weekdays.sorted().map(String.init).joined(separator: ",") ?? "", time == nil ? "context" : proactiveDay(day)]
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func triggerDescription(_ trigger: RuleTrigger) -> String {
        var parts = trigger.apps.sorted()
        if let state = trigger.state { parts.append(state) }
        if let time = trigger.time {
            func label(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
            parts.append("\(label(time.startMinute))–\(label(time.endMinute)). Window until \(label(time.endMinute))")
        } else { parts.append("Window until this context stops matching") }
        return parts.joined(separator: "; ")
    }
}
