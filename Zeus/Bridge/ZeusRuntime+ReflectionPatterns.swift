import Foundation
import ZeusProtocol

extension ZeusRuntime {
    /// Bound provenance independently of the displayed citations; deletion of an uncited contributor still invalidates the aggregate.
    func reflectionSourcesRetained(_ delivery: Delivery, items: [JournalItem]) -> Bool {
        guard let expected = delivery.meta["source_hash"] else {
            let retained = Set(items.map(\.id))
            return delivery.meta["evidence", default: ""].split(separator: ",").allSatisfy { retained.contains(String($0)) }
        }
        guard let from = Double(delivery.meta["source_from", default: ""]), let to = Double(delivery.meta["source_to", default: ""]) else { return false }
        let levels = Set(delivery.meta["levels", default: ""].split(separator: ",").compactMap { Int($0).flatMap(JournalLevel.init(rawValue:)) })
        let ids = items.filter { ReflectionPatternDigest.eligible($0, levels: levels, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to)) }.map(\.id)
        return ReflectionPatternDigest.sourceHash(ids) == expected
    }

    /// Feedback IDs are separate from capture evidence so a card is never mistaken for a journal record.
    func reflectionFeedback() -> [ReflectionPatternDigest.Feedback] {
        var result: [ReflectionPatternDigest.Feedback] = []
        for signal in messageRatings?.state.signals.values ?? Dictionary<String, MessageRatingStore.Signal>().values {
            guard let card = cards.card(id: signal.id) else { continue }
            let state: String
            if let response = card.response { state = response.skipped ? "skipped" : "answered" }
            else if signal.opened != nil { state = "opened" }
            else if signal.shown != nil && signal.created.addingTimeInterval(86400) < clock.now { state = "shown but not opened after a day" }
            else { continue }
            result.append(.init(reference: .init(id: signal.id, at: signal.created, journal: false), label: signal.label, state: state))
        }
        for rating in ratings {
            let value = rating.rating == .up ? "rated Up" : (rating.rating == .down ? "rated Stop" : "rated Need-to-know")
            result.append(.init(reference: .init(id: rating.id, at: rating.updatedAt, journal: false), label: rating.kindLabel, state: value))
        }
        return result
    }
    func reflectionFeedbackDates() -> [String: Date] {
        var dates = Dictionary(reflectionFeedback().map { ($0.reference.id, $0.reference.at) }, uniquingKeysWith: { first, _ in first })
        for event in (learningRules as? any RuleLifecycleStoring)?.outcomeEvents ?? [] { dates[event.id] = event.at }
        return dates
    }
    static func reflectionRequest(date: String, budget: String) -> String {
        """
        Zeus reflection for \(date). A redacted summary of how I've used my Mac over the last 28 days, built on this Mac. It isn't a new request from me; it's your evening to learn and get ahead.

        Do these, in this order:
        1. Update your notes. Revise Notes/about-you.md (what you've concluded about me) and Notes/patterns.md (my routines and recurring tasks) from the patterns below. Date each change and say what changed your mind. Conclusions, not copies: don't paste these lines in.
        2. Propose rules, if any. Call zeus_get_rules, then zeus_propose_rules with at most three, only for a pattern that held on two or more days, each with two evidence IDs from different days taken from the lines below. Don't propose anything listed under "Don't propose again", even reworded. Use app names shown below or bundle IDs in trigger.apps; time is local minutes after midnight (07:45 = 465). Check each indexed proposal result and retry only rejected rules. Acting rules start in shadow; every purchase asks.
        3. Get ahead of tomorrow. If one thing needs preparing or flagging (something due, a meeting, a reply I owe, a task I keep putting off), do the prep and send me one short message with an about label. Otherwise zeus_ack and stay quiet. \(budget)
        Never repeat my habits, numbers or private details back to me. A placeholder like ‹name› is something Zeus removed: don't guess it, don't ask me for it.
        """
    }
    static func boundedReflectionText(_ text: String, bytes: Int) -> String {
        var value = text
        while value.utf8.count > max(0, bytes) { value.removeLast() }
        return value
    }
    func reflectionOutcomeText(since: Date, now: Date, sentenceText: (String) -> String = { $0 }) -> String {
        let local = ReflectionLocalTime(calendar: learningCalendar)
        let lifecycle = learningRules as? any RuleLifecycleStoring
        let events = (lifecycle?.outcomeEvents ?? []).filter { $0.at > since && $0.at <= now }
        let labels: [RuleOutcome: String] = [.accepted: "accepted", .skipped: "skipped", .undone: "undone", .ignored: "ignored", .toggledOff: "turned off", .toggledOn: "turned on", .edited: "edited", .stale: "not matched for a month"]
        var lines: [String] = []
        for event in events.sorted(by: { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }).suffix(12) {
            let sentence = learningRules?.rules.first { $0.id == event.ruleID }?.sentence ?? "A removed rule"
            let cause = event.source == .explicit ? "explicitly" : "from observed feedback"
            lines.append("- “\(ReflectionPatternDigest.clean(sentenceText(sentence), limit: 100))”: \(labels[event.outcome] ?? "changed") \(cause). [\(event.id) \(local.label(event.at))]")
        }
        var text = lines.isEmpty ? "" : "Rule outcomes since the last reflection\n" + lines.joined(separator: "\n")
        let blocked = (lifecycle?.suppressedRules ?? []).filter { $0.until > now }.sorted { $0.fingerprint < $1.fingerprint }
        if !blocked.isEmpty {
            text += "\n\nDon't propose again\n" + blocked.prefix(8).map { value in
                let reason = value.reason == "deleted" ? "you deleted it" : (value.reason == "retired" ? "retired" : "you turned it off")
                return "- “\(ReflectionPatternDigest.clean(sentenceText(value.sentence), limit: 100))” (\(reason), until \(local.label(value.until, "d MMM")))."
            }.joined(separator: "\n")
        }
        return text
    }
}
