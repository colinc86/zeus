import Foundation
import CryptoKit
import Observation
import ZeusProtocol

extension ZeusRuntime: LearningRuntimeControlling {
    func startLearning() {
        learningObservationToken = UUID()
        learningCatchUpPending = true
        (learningRules as? any LearningRuleOutcomeSource)?.onRuleOutcome = { [weak self] outcome, ids, eventID, at in
            self?.recordJournalOutcome(outcome, ruleIDs: ids, eventID: eventID, at: at)
        }
        observeLearning()
        learningContextDidChange()
    }
    func stopLearning() {
        learningObservationToken = UUID()
        (learningRules as? any LearningRuleOutcomeSource)?.onRuleOutcome = nil
        learningTimer?.cancel(); learningTimer = nil
        reflectionTask?.cancel(); reflectionTask = nil
        learningHeldIDs.removeAll(); learningInterruptionHold = false
    }
    private func observeLearning() {
        let token = learningObservationToken
        withObservationTracking {
            _ = learningRules?.revision; _ = learningRules?.autonomy; _ = learningJournal?.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.learningObservationToken == token else { return }
                self.observeLearning(); self.learningContextDidChange()
            }
        }
    }
    /// Frontmost app/state and consent are supplied by the app, never inferred from raw journal text.
    func learningContextDidChange() {
        guard running else { return }
        reconcileReflectionEvidence()
        let context = learningContext(), now = clock.now
        if !reflectionEnabled() || context.isLocked || context.isPrivate { reflectionTask?.cancel() }
        let matching = matchingLearningRules(context: context, at: now)
        let hold = matching.contains { $0.kind == .passive }
        if learningInterruptionHold && !hold {
            let ids = learningHeldIDs; learningHeldIDs.removeAll()
            learningInterruptionHold = false; onLearningHoldCleared?(ids)
        } else { learningInterruptionHold = hold }
        do {
            try reconnectRuleNotices(matching: matching)
            try recordIgnoredQuestions()
        } catch { learningError = "Zeus couldn't save a learning outcome. It will try again." }
        considerReflection()
        scheduleLearningBoundary()
    }
    private func matchingLearningRules(context: LearningContext, at now: Date) -> [LearnedRule] {
        (learningRules?.rules ?? []).filter {
            ($0.status == .active || $0.status == .shadow) && $0.trigger.matches(context, at: now, calendar: learningCalendar)
        }
    }
    private func applicableLearningRuleIDs() -> [String] {
        let context = learningContext()
        return (learningRules?.rules ?? []).filter {
            $0.status == .active && (!$0.trigger.isEvaluable || $0.trigger.matches(context, at: clock.now, calendar: learningCalendar))
        }.map(\.id)
    }
    func prepareLearningCard(_ card: Card) throws {
        guard let rules = learningRules else { return }
        // Refresh before CardStore.onArrival can peek; Observation/context callbacks may still be queued.
        learningContextDidChange()
        let ids = applicableLearningRuleIDs()
        if !ids.isEmpty {
            try (rules as? any LearningRuleTracking)?.associate(cardID: card.id, ruleIDs: ids)
        }
        if card.kind == .question || !ids.isEmpty { learningCardRules[card.id] = ids }
        if learningInterruptionHold && card.priority != .high { learningHeldIDs.append(card.id) }
    }
    private func recordJournalOutcome(_ outcome: RuleOutcome, ruleIDs: [String], eventID: String, at date: Date) {
        guard running, reflectionEnabled(), let journal = learningJournal else { return }
        let description: String = switch outcome {
        case .accepted: "Accepted an assistant result"
        case .skipped: "Skipped an assistant question"
        case .undone: "Undid an assistant change"
        case .ignored: "An assistant question went unanswered for a day"
        case .toggledOff: "Turned off or deferred a learned rule"
        case .toggledOn: "Approved a learned rule"
        case .edited: "Edited a learned rule"
        }
        let payload = JournalPayload(description: description, details: ["outcome": outcome.rawValue, "rule_ids": ruleIDs.joined(separator: ",")])
        do { try journal.append(.init(id: "outcome:" + eventID, time: date, level: .activity, kind: .outcome, payload: .init(payload))) }
        catch { learningError = "Zeus couldn't save a learning outcome to the journal." }
    }
    func recordRuleAnswer(_ card: Card, response: CardResponse) {
        let ids = learningCardRules[card.id] ?? (learningRules as? any LearningRuleTracking)?.associatedRuleIDs(cardID: card.id) ?? []
        do {
            try learningRules?.recordOutcome(response.skipped ? .skipped : .accepted, ruleIDs: ids,
                eventID: "answer:" + card.id, at: response.respondedAt)
        } catch { learningError = "Zeus couldn't save this rule outcome." }
    }
    func recordLearningOutcome(_ outcome: RuleOutcome, ruleIDs: [String]) {
        do { try learningRules?.recordOutcome(outcome, ruleIDs: ruleIDs, at: clock.now) }
        catch { learningError = "Zeus couldn't save this rule outcome." }
    }
    func learningTrackedChange(_ change: AppChange) -> AppChange {
        let ids = applicableLearningRuleIDs()
        guard !ids.isEmpty || (learningRules != nil && reflectionEnabled()) else { return change }
        let event = "undo:" + UUID().uuidString
        return AppChange(summary: change.summary, undoTitle: change.undoTitle, undo: { [weak self] in
            change.undo()
            guard let self else { return }
            do { try self.learningRules?.recordOutcome(.undone, ruleIDs: ids, eventID: event, at: self.clock.now) }
            catch { self.learningError = "Zeus couldn't save this rule outcome." }
        })
    }
    private func recordIgnoredQuestions() throws {
        let knownIDs = Set(learningCardRules.keys).union((cards as? any CardPersistenceReporting)?.persistedCards.map(\.id) ?? [])
        for id in knownIDs {
            guard let card = cards.card(id: id), card.kind == .question, card.status == .open, !handledResponses.contains(id),
                  card.createdAt.addingTimeInterval(86400) < clock.now else { continue }
            let ids = learningCardRules[id] ?? (learningRules as? any LearningRuleTracking)?.associatedRuleIDs(cardID: id) ?? []
            try learningRules?.recordOutcome(.ignored, ruleIDs: ids, eventID: "ignored:" + id, at: clock.now)
        }
    }
    private func reconnectRuleNotices(matching: [LearnedRule]) throws {
        guard let recorder = cards as? any LearningNoticeRecording else { return }
        let allRules = learningRules?.rules ?? []
        let tracking = learningRules as? any LearningRuleTracking
        let groups = tracking?.ruleNoticeGroups() ?? allRules.map { [$0.id] }
        for ids in groups {
            let members = ids.compactMap { id in allRules.first { $0.id == id } }
            guard let first = members.first, let groupID = ids.first else { continue }
            let summary = members.count == 1 ? "New rule: \(first.sentence)" : "\(members.count) new rules"
            recorder.recordLearningNotice(.init(id: "rule:" + groupID, kind: .newRule, createdAt: first.created,
                summary: summary, actionTitle: "Review", detail: members.map(\.sentence).joined(separator: "\n"), ruleID: members.count == 1 ? first.id : nil),
                action: { [weak self] in self?.onReviewRule?(first.id) })
        }
        for rule in allRules where rule.kind == .acts {
            if rule.status == .shadow {
                guard !rule.trigger.isEvaluable || matching.contains(where: { $0.id == rule.id }) else { continue }
                _ = try tracking?.markShadowShown(id: rule.id)
                let recorded = recorder.recordLearningNotice(.init(id: "shadow:" + rule.id, kind: .shadow, createdAt: rule.created,
                    summary: "I'd have: \(rule.sentence)", actionTitle: "OK next time?", detail: rule.sentence, ruleID: rule.id), action: { [weak self] in
                    guard let self, self.learningRules?.rules.first(where: { $0.id == rule.id })?.status == .shadow else { return }
                    do { try self.learningRules?.setStatus(.active, id: rule.id, at: self.clock.now); self.learningContextDidChange() }
                    catch { self.learningError = "Zeus couldn't activate this rule." }
                })
                if recorded, learningRules?.autonomy == 1 {
                    try learningRules?.recordOutcome(.accepted, ruleIDs: [rule.id], eventID: "shadow-result:" + rule.id, at: clock.now)
                }
            } else if tracking?.hasShadowShown(id: rule.id) == true {
                let approved = rule.status == .active
                var action: (@MainActor () -> Void)?
                if approved { action = { @MainActor [weak self] in
                    guard let self else { return }
                    do { try (self.learningRules as? any LearningRuleTracking)?.undoShadowApproval(id: rule.id, at: self.clock.now); self.learningContextDidChange() }
                    catch { self.learningError = "Zeus couldn't undo this rule approval." }
                } }
                recorder.recordLearningNotice(.init(id: "shadow:" + rule.id, kind: .shadow, createdAt: rule.created,
                    summary: approved ? "OK. I will do that from now on." : "Rule retired: \(rule.sentence)",
                    actionTitle: approved ? "Undo" : nil, detail: rule.sentence, ruleID: rule.id), action: action)
            }
        }
    }

    /// Reflection uses the durable ordinary delivery path, with its own wire kind and no fabricated user bubble.
    private func considerReflection() {
        guard reflectionTask == nil, reflectionEnabled(), let journal = learningJournal, let redactor = learningRedactor,
              learningRules != nil, let target = assistantTarget, let session = sessions.first(where: { $0.sessionKey == target }),
              !learningContext().isLocked, !learningContext().isPrivate else { return }
        let now = clock.now, context = learningContext(), calendar = learningCalendar
        let today = calendar.startOfDay(for: now)
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: today) ?? today
        // A catch-up and this evening cannot both send on the same local day.
        guard !(ledger?.records ?? []).contains(where: { $0.delivery.kind == .reflection && calendar.isDate($0.delivery.createdAt, inSameDayAs: now) }) else { return }
        var query = JournalQuery(); query.levels = [.activity, .focus]
        query.kinds = [.activity, .focus, .description, .outcome]; query.limit = 100_000
        let available: [JournalItem]
        do { available = try journal.items(matching: query) }
        catch { learningError = "Zeus couldn't read the day's journal for reflection."; return }
        let day: Date
        if now >= evening, let idle = context.idleSince, now.timeIntervalSince(idle) >= 600,
           available.contains(where: { calendar.isDate($0.time, inSameDayAs: today) }) { day = today }
        else if learningCatchUpPending {
            guard let previous = available.last(where: { $0.time < today }) else { return }
            day = calendar.startOfDay(for: previous.time)
        } else { return }
        let dayKey = reflectionDayKey(day), id = "d_reflection_" + dayKey
        guard ledger?.record(id: id) == nil else { learningCatchUpPending = false; return }
        let items = available.filter { calendar.isDate($0.time, inSameDayAs: day) }
        guard !items.isEmpty else { return }
        // Bound the summary and include only evidence actually presented to the model.
        var lines: [String] = [], evidence: [String] = [], bytes = 0
        for item in items.reversed() {
            let line = "\(item.time.ISO8601Format()) \(item.payload.value.description)"
            guard bytes + line.utf8.count <= 8000 else { break }
            lines.append(line); evidence.append(item.id); bytes += line.utf8.count
        }
        guard !lines.isEmpty else { return }
        let token = generation, observationToken = learningObservationToken, revision = journal.revision
        reflectionTask = Task { [weak self] in
            let safe = await redactor.redact(lines.reversed().joined(separator: "\n"))
            guard let self, self.generation == token, self.learningObservationToken == observationToken else { return }
            defer {
                self.reflectionTask = nil; self.scheduleLearningBoundary()
                if Task.isCancelled || journal.revision != revision { self.considerReflection() }
            }
            guard self.running, !Task.isCancelled, self.reflectionEnabled(), journal.revision == revision,
                  !self.learningContext().isPrivate, !self.learningContext().isLocked,
                  self.assistantTarget == target, self.sessions.contains(where: { $0.id == session.id }), self.ledger?.record(id: id) == nil else { return }
            if calendar.isDate(day, inSameDayAs: today) {
                guard let idle = self.learningContext().idleSince, self.clock.now.timeIntervalSince(idle) >= 600 else { return }
            }
            let content = """
            Zeus reflection for \(dayKey). This is a redacted local summary, not a new user request.
            Read zeus_get_rules. Propose at most two useful rules with zeus_propose_rules; evidence must use IDs below.
            Prefer timing/tone/preparation rules. External acts start in shadow; do not execute them. Do not repeat habits or private details to the user.
            \(safe.value)
            Evidence IDs (already-redacted journal records): \(evidence.joined(separator: ", "))
            """
            var delivery = Delivery(id: id, kind: .reflection, sessionKey: target, content: content, createdAt: self.clock.now)
            delivery.meta = ["kind": "reflection", "delivery_id": id, "reflection_day": dayKey,
                             "evidence": evidence.joined(separator: ",")]
            do {
                try self.ledger?.insert(.init(delivery: delivery))
                self.learningCatchUpPending = false
                _ = self.beginSend(id: id)
            } catch { self.learningError = "Zeus couldn't save its reflection delivery." }
        }
    }
    func recordReflectionReceipt(id: String) {
        guard let record = ledger?.record(id: id), record.delivery.kind == .reflection, !record.delivery.content.isEmpty else { return }
        if let journal = learningJournal {
            var query = JournalQuery(); query.limit = 100_000
            guard let items = try? journal.items(matching: query) else { return }
            let retained = Set(items.map(\.id))
            guard record.delivery.meta["evidence", default: ""].split(separator: ",").allSatisfy({ retained.contains(String($0)) }) else {
                reconcileReflectionEvidence(); return
            }
        }
        recordSentLearning(id: id, kind: "reflection", text: .init(record.delivery.content), sessionKey: record.delivery.sessionKey)
    }
    /// Only callers holding the actual successful notification/tool-result bytes use this receipt path.
    func recordSentLearning(id: String, kind: String, text: Redacted<String>, sessionKey: String) {
        guard let journal = learningJournal else { return }
        let identity = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let receiptID = "sent:" + id + ":" + identity.prefix(24)
        do {
            var query = JournalQuery(); query.kinds = [.sentToAssistant]; query.limit = 100_000
            guard try !journal.items(matching: query).contains(where: { $0.id == receiptID }) else { return }
            let agent = sessions.first(where: { $0.sessionKey == sessionKey })?.agent.rawValue ?? sessionKey.split(separator: ":").first.map(String.init) ?? "other"
            let agentLabel = ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode"][agent] ?? "Assistant"
            let label = agentLabel + (managedController.sessionKey == sessionKey ? " · Zeus" : " · Assistant")
            let summary = kind == "reflection" ? "Sent a daily reflection" : (kind == "digest" ? "Sent your daily summary" : "Sent a note")
            let payload = JournalPayload(description: summary, text: text.value,
                details: ["kind": kind, "delivery_id": id, "agent": agent, "sessionLabel": label, "sessionID": identity])
            try journal.append(.init(id: receiptID, time: clock.now, level: .activity, kind: .sentToAssistant,
                payload: .init(payload, report: text.report)))
        } catch { learningError = "Zeus couldn't record this learning receipt." }
    }
    func learningForSending(_ learning: Learning) async -> Learning {
        guard let redactor = learningRedactor else { return learning }
        let text = await redactor.redact(learning.text)
        return Learning(id: learning.id, kind: learning.kind, createdAt: learning.createdAt, text: text.value)
    }
    func recordLearningToolReceipts(_ items: [JSONValue], sessionKey: String) {
        for value in items {
            guard let data = try? ZeusJSON.encoder().encode(value), let learning = try? ZeusJSON.decoder().decode(Learning.self, from: data) else { continue }
            // The tool result contains learningForSending output, never a newly reconstructed summary.
            recordSentLearning(id: learning.id, kind: learning.kind.rawValue, text: .init(learning.text), sessionKey: sessionKey)
        }
    }
    /// Erasing source evidence also erases any retained reflection body and stops its retry, while preserving the daily tombstone.
    private func reconcileReflectionEvidence() {
        guard let journal = learningJournal, let ledger else { return }
        let reflections = ledger.records.filter { $0.delivery.kind == .reflection && !$0.delivery.content.isEmpty }
        guard !reflections.isEmpty else { return }
        do {
            var query = JournalQuery(); query.limit = 100_000
            let retained = Set(try journal.items(matching: query).map(\.id))
            let erased = Set(reflections.filter { record in
                let evidence = record.delivery.meta["evidence", default: ""].split(separator: ",").map(String.init)
                // A journaled paste must keep its exact recovery payload until submitted once; never strand Zeus's own input.
                return record.delivery.meta["tmux_paste_destination"] == nil && !evidence.allSatisfy(retained.contains)
            }.map { $0.delivery.id })
            guard !erased.isEmpty else { return }
            for id in erased { sends[id]?.cancel(); sendTokens.removeValue(forKey: id) }
            try ledger.mutateRecords { records in
                for index in records.indices where erased.contains(records[index].delivery.id) {
                    records[index].delivery.content = ""
                    records[index].delivery.meta.removeValue(forKey: "evidence")
                    if records[index].isPending { records[index].discardedAt = clock.now }
                }
            }
        } catch { learningError = "Zeus couldn't reconcile deleted reflection evidence." }
    }
    private func reflectionDayKey(_ date: Date) -> String {
        let c = learningCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func scheduleLearningBoundary() {
        learningTimer?.cancel(); learningTimer = nil
        guard learningRules != nil || (learningJournal != nil && reflectionEnabled()) else { return }
        let now = clock.now
        // Minute boundaries are needed only while a timed rule exists; otherwise schedule exact idle/evening deadlines.
        var dates: [Date] = []
        if learningRules?.rules.contains(where: { $0.trigger.time != nil && ($0.status == .active || $0.status == .shadow) }) == true {
            dates.append(Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60))
        }
        let evening = learningCalendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
        if reflectionEnabled() {
            if now < evening { dates.append(evening) }
            else if let idle = learningContext().idleSince, idle.addingTimeInterval(600) > now { dates.append(idle.addingTimeInterval(600)) }
            if let tomorrow = learningCalendar.date(byAdding: .day, value: 1, to: learningCalendar.startOfDay(for: now)) { dates.append(tomorrow) }
        }
        for id in learningCardRules.keys {
            if let card = cards.card(id: id), card.status == .open, card.kind == .question {
                let date = card.createdAt.addingTimeInterval(86400.001); if date > now { dates.append(date) }
            }
        }
        guard let deadline = dates.min() else { return }
        let token = generation, clock = self.clock
        learningTimer = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, self.running, self.generation == token, !Task.isCancelled else { return }
            self.learningTimer = nil; self.learningContextDidChange()
        }
    }
    func callRuleTool(_ name: String, args: ToolArguments, sessionKey: String) async throws -> ToolResult {
        guard let rules = learningRules else { throw ToolArgumentError("Rules aren't available in this Zeus instance.") }
        if name == "zeus_get_rules" {
            return result(["rules": .array(try rules.rules.filter { $0.status == .active || $0.status == .shadow }.map(JSONValue.from)),
                           "autonomy": .number(rules.autonomy)])
        }
        guard let journal = learningJournal, let redactor = learningRedactor,
              case .array(let array) = args.values["rules"], !array.isEmpty, array.count <= 20 else {
            throw ToolArgumentError("rules must contain 1–20 rule proposals; local learning must be configured.")
        }
        let token = generation, sessionID = sessions.first { $0.sessionKey == sessionKey }?.id
        var query = JournalQuery(); query.limit = 100_000
        let existingEvidence = Set(try journal.items(matching: query).map(\.id))
        var proposals: [RuleProposal] = []
        for value in array {
            let normalized = try normalizedRule(value)
            var proposal = try JSONDecoder().decode(RuleProposal.self, from: JSONEncoder().encode(normalized))
            guard proposal.evidence.allSatisfy(existingEvidence.contains) else { throw ToolArgumentError("Rule evidence must reference retained journal item IDs.") }
            guard !proposal.sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposal.sentence.count <= 500 else { throw ToolArgumentError("Rule sentence must contain 1–500 characters.") }
            proposal.sentence = await redactor.redact(proposal.sentence).value
            guard running, generation == token, sessions.first(where: { $0.sessionKey == sessionKey })?.id == sessionID,
                  sessionID != nil else { throw CancellationError() }
            proposals.append(proposal)
        }
        // Revalidate evidence after async redaction: Delete Everything must not be undone by a late proposal.
        let retained = Set(try journal.items(matching: query).map(\.id))
        guard proposals.allSatisfy({ $0.evidence.allSatisfy(retained.contains) }) else { throw ToolArgumentError("Rule evidence was deleted while processing the proposal.") }
        let added = try rules.propose(proposals, at: clock.now)
        learningContextDidChange()
        return result(["rules": .array(try rules.rules.filter { rule in added.contains { $0.id == rule.id } }.map(JSONValue.from))])
    }
    private func normalizedRule(_ value: JSONValue) throws -> JSONValue {
        guard case .object(var fields) = value, Set(fields.keys).isSubset(of: ["sentence", "trigger", "kind", "confidence", "evidence"]), fields["sentence"] != nil else { throw ToolArgumentError("Invalid rule proposal fields.") }
        if fields["kind"] == nil { fields["kind"] = "passive" }
        if fields["confidence"] == nil { fields["confidence"] = .number(0.6) }
        if fields["evidence"] == nil { fields["evidence"] = [] }
        var trigger: [String: JSONValue] = [:]
        if let raw = fields["trigger"] {
            guard case .object(let object) = raw, Set(object.keys).isSubset(of: ["time", "apps", "state"]) else { throw ToolArgumentError("Invalid rule trigger.") }
            trigger = object
        }
        if trigger["apps"] == nil { trigger["apps"] = [] }
        if let raw = trigger["time"] {
            guard case .object(var time) = raw, Set(time.keys).isSubset(of: ["startMinute", "endMinute", "weekdays"]) else { throw ToolArgumentError("Invalid time trigger.") }
            if time["weekdays"] == nil { time["weekdays"] = [] }; trigger["time"] = .object(time)
        }
        fields["trigger"] = .object(trigger); return .object(fields)
    }
}
