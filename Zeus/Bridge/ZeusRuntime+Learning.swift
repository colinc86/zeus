import Foundation
import CryptoKit
import Observation
import ZeusProtocol

extension ZeusRuntime: LearningRuntimeControlling {
    func startLearning() {
        learningObservationToken = UUID()
        learningCatchUpPending = true
        (learningJournal as? any JournalDeletionObserving)?.onJournalDeletion = { [weak self] ids in self?.journalEvidenceDeleted(ids) }
        (learnings as? any LearningDeletionObserving)?.onLearningDeletion = { [weak self] ids in self?.eraseLearningDeliveries(ids: ids) }
        if let source = learnings as? any LearningDeletionObserving {
            eraseLearningDeliveries(ids: Set((ledger?.records ?? []).filter { $0.delivery.kind == .learning && $0.delivery.meta["learning_kind"] != "rating" && !source.retainedLearningIDs.contains($0.delivery.id) }.map { $0.delivery.id }))
        }
        (learningRules as? any LearningRuleOutcomeSource)?.onRuleOutcome = { [weak self] outcome, ids, eventID, at in
            self?.recordJournalOutcome(outcome, ruleIDs: ids, eventID: eventID, at: at)
        }
        reconnectJournalAnswerNotices()
        observeLearning()
        learningContextDidChange()
    }
    func stopLearning() {
        (learningJournal as? any JournalDeletionObserving)?.onJournalDeletion = nil
        (learnings as? any LearningDeletionObserving)?.onLearningDeletion = nil
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
        for pending in Array(journalAnswerReceipts.values) where pending.3 { recordJournalAnswerReceipt(pending.0, sessionKey: pending.1) }
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
            if let lifecycle = learningRules as? any RuleLifecycleStoring {
                try lifecycle.noteMatches(ids: matching.map(\.id), at: now)
                try lifecycle.advanceOutcomes(at: now)
                reconnectPhaseDNotices()
            }
            try reconnectRuleNotices(matching: matching)
            try recordIgnoredQuestions()
        } catch { learningError = "Zeus couldn't save a learning outcome. It will try again." }
        considerMorningBrief()
        expireStaleLearningDeliveries()
        reconcileProactiveDeliveries(matching: matching)
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
        case .stale: "A learned rule has not applied for a month"
        }
        let payload = JournalPayload(description: description, details: ["outcome": outcome.rawValue, "rule_ids": ruleIDs.joined(separator: ",")])
        do { try journal.append(.init(id: "outcome:" + eventID, time: date, level: .activity, kind: .outcome, payload: .init(payload))) }
        catch { learningError = "Zeus couldn't save a learning outcome to the journal." }
    }
    func recordRuleAnswer(_ card: Card, response: CardResponse) {
        if recordSpendAnswer(card, response: response) { return }
        let ids = learningCardRules[card.id] ?? (learningRules as? any LearningRuleTracking)?.associatedRuleIDs(cardID: card.id) ?? []
        do {
            if let lifecycle = learningRules as? any RuleLifecycleStoring {
                try lifecycle.recordSignal(response.skipped ? .skipped : .accepted, source: response.skipped ? .timedQuestion : .explicit,
                    ruleIDs: ids, eventID: "answer:" + card.id, at: response.respondedAt)
            } else { try learningRules?.recordOutcome(response.skipped ? .skipped : .accepted, ruleIDs: ids, eventID: "answer:" + card.id, at: response.respondedAt) }
        } catch { learningError = "Zeus couldn't save this rule outcome." }
    }
    func recordLearningOutcome(_ outcome: RuleOutcome, ruleIDs: [String]) {
        do {
            if let lifecycle = learningRules as? any RuleLifecycleStoring {
                try lifecycle.recordSignal(outcome, source: outcome == .accepted ? .heldRead : (outcome == .undone ? .holdShown : .explicit),
                    ruleIDs: ruleIDs, eventID: UUID().uuidString, at: clock.now)
            } else { try learningRules?.recordOutcome(outcome, ruleIDs: ruleIDs, at: clock.now) }
        }
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
            guard let card = cards.card(id: id), card.status == .open, !handledResponses.contains(id),
                  card.createdAt.addingTimeInterval(86400) < clock.now else { continue }
            let ids = learningCardRules[id] ?? (learningRules as? any LearningRuleTracking)?.associatedRuleIDs(cardID: id) ?? []
            if card.kind != .question {
                guard let reads = cards as? any LearningCardReadState, !reads.learningCardWasRead(id: id), !ids.isEmpty else { continue }
            }
            if let lifecycle = learningRules as? any RuleLifecycleStoring {
                try lifecycle.recordSignal(.ignored, source: .resultIgnored, ruleIDs: ids, eventID: "ignored:" + id, at: clock.now)
            } else { try learningRules?.recordOutcome(.ignored, ruleIDs: ids, eventID: "ignored:" + id, at: clock.now) }
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
        // Phase D notices represent an actual shadow report, not an inferred action at proposal time.
        guard !(learningRules is any RuleLifecycleStoring) else { return }
        for rule in allRules where rule.kind == .acts {
            if rule.status == .shadow {
                guard !rule.trigger.isEvaluable || matching.contains(where: { $0.id == rule.id }) else { continue }
                _ = try tracking?.markShadowShown(id: rule.id)
                let recorded = recorder.recordLearningNotice(.init(id: "shadow:" + rule.id, kind: .shadow, createdAt: rule.created,
                    summary: "I'd have acted on “\(rule.sentence)”", actionTitle: "OK next time?", detail: rule.sentence, ruleID: rule.id), action: { [weak self] in
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
                if rule.status == .retired { action = { @MainActor [weak self] in self?.onReviewRule?(rule.id) } }
                recorder.recordLearningNotice(.init(id: "shadow:" + rule.id, kind: .shadow, createdAt: rule.created,
                    summary: approved ? "OK. I'll do that from now on." : (rule.status == .retired ? "Retired: “\(rule.sentence)”" : "Got it. I won't."),
                    actionTitle: approved ? "Undo" : (rule.status == .retired ? "Review" : nil), detail: rule.sentence, ruleID: rule.id), action: action)
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
        guard !(ledger?.records ?? []).contains(where: { $0.delivery.kind == .reflection && $0.delivery.meta["discard_reason"] != "superseded" && calendar.isDate($0.delivery.createdAt, inSameDayAs: now) }) else { return }
        let permittedLevels = journalAccessPolicy().enabledLevels
        guard !permittedLevels.isEmpty else { return }
        var query = JournalQuery(); query.levels = permittedLevels
        // A catch-up day also needs its preceding 27 days; the digest itself always selects exactly 28 local days.
        query.from = calendar.date(byAdding: .day, value: -55, to: today); query.to = now.addingTimeInterval(0.001)
        query.kinds = [.activity, .focus, .description, .typedText, .outcome]; query.limit = 100_000
        let available: [JournalItem]
        do { available = try journal.items(matching: query) }
        catch { learningError = "Zeus couldn't read the day's journal for reflection."; return }
        let day: Date
        if now >= evening, let idle = context.idleSince, now.timeIntervalSince(idle) >= 600,
           available.contains(where: { calendar.isDate($0.time, inSameDayAs: today) }) { day = today }
        else if learningCatchUpPending {
            let oldestCatchUp = calendar.date(byAdding: .day, value: -28, to: today) ?? today
            guard let previous = available.last(where: { $0.time < today && $0.time >= oldestCatchUp }) else { return }
            day = calendar.startOfDay(for: previous.time)
        } else { return }
        let dayKey = reflectionDayKey(day), baseID = "d_reflection_" + dayKey
        // Never reuse a legacy tombstone: its late ack belongs only to that old body.
        let id = ledger?.record(id: baseID)?.delivery.meta["discard_reason"] == "superseded"
            ? baseID + "_patterns" : baseID
        guard ledger?.record(id: id) == nil else { learningCatchUpPending = false; return }
        let local = ReflectionLocalTime(calendar: calendar)
        let digest = ReflectionPatternDigest(time: local, day: day, levels: permittedLevels, items: available, feedback: reflectionFeedback()).build(byteLimit: 6_200)
        guard !digest.references.isEmpty else { return }
        let evidence = digest.references.filter(\.journal).map(\.id)
        let initialFeedbackDates = Dictionary(digest.references.filter { !$0.journal }.map { ($0.id, $0.at.timeIntervalSince1970) }, uniquingKeysWith: { first, _ in first })
        let lastReflection = (ledger?.records ?? []).filter { $0.delivery.kind == .reflection && $0.discardedAt == nil }.map { $0.delivery.createdAt }.max() ?? .distantPast
        var feedbackSentences: [(String, String)] = []
        let feedback = reflectionOutcomeText(since: lastReflection, now: now) { sentence in
            let marker = "‹rule-sentence-\(feedbackSentences.count)›"
            feedbackSentences.append((marker, sentence)); return marker
        }
        let token = generation, observationToken = learningObservationToken, revision = journal.revision
        reflectionTask = Task { [weak self] in
            // Redact user-authored sentences before adding generated dates, outcomes and evidence IDs.
            var safeFeedback = feedback
            for (marker, sentence) in feedbackSentences {
                let safe = await redactor.redact(sentence)
                safeFeedback = safeFeedback.replacingOccurrences(of: marker, with: safe.value)
            }
            guard let self, self.generation == token, self.learningObservationToken == observationToken else { return }
            defer {
                self.reflectionTask = nil; self.scheduleLearningBoundary()
                if Task.isCancelled || journal.revision != revision { self.considerReflection() }
            }
            guard self.running, !Task.isCancelled, self.reflectionEnabled(), self.journalAccessPolicy().enabledLevels == permittedLevels, journal.revision == revision,
                  !self.learningContext().isPrivate, !self.learningContext().isLocked,
                  self.assistantTarget == target, self.sessions.contains(where: { $0.id == session.id }), self.ledger?.record(id: id) == nil else { return }
            if calendar.isDate(day, inSameDayAs: today) {
                guard let idle = self.learningContext().idleSince, self.clock.now.timeIntervalSince(idle) >= 600 else { return }
            }
            let request = Self.reflectionRequest(date: local.label(day, "EEEE d MMMM"), budget: self.proactiveBudgetLine)
            var content = request + "\n\n" + digest.text
            if !safeFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content += "\n\n" + Self.boundedReflectionText(safeFeedback, bytes: 1_600)
            }
            let preferences = MessageRatingStore.preferences(self.ratings)
            if !self.ratings.isEmpty { content += "\n\nMessage preferences:\n" + Self.boundedReflectionText(preferences, bytes: 600) }
            content = Self.boundedReflectionText(content, bytes: 10_000)
            var feedbackDates = initialFeedbackDates
            for (id, date) in self.reflectionFeedbackDates() where content.contains("[" + id + " ") {
                feedbackDates[id] = date.timeIntervalSince1970
            }
            let paths = await self.learningFolder?.recordReflection(id: id, text: .init(content), at: self.clock.now) ?? []
            guard self.running, !Task.isCancelled, self.generation == token,
                  self.learningObservationToken == observationToken, self.reflectionEnabled(), self.journalAccessPolicy().enabledLevels == permittedLevels, journal.revision == revision,
                  !self.learningContext().isPrivate, !self.learningContext().isLocked,
                  self.assistantTarget == target, self.sessions.contains(where: { $0.id == session.id }), self.ledger?.record(id: id) == nil else { return }
            content = Self.withLearningFiles(content, paths: paths)
            var delivery = Delivery(id: id, kind: .reflection, sessionKey: target, content: content, createdAt: self.clock.now)
            delivery.meta = ["kind": "reflection", "delivery_id": id, "reflection_day": dayKey,
                             "evidence": evidence.joined(separator: ","),
                             "source_hash": ReflectionPatternDigest.sourceHash(digest.sourceIDs),
                             "source_from": String((calendar.date(byAdding: .day, value: -27, to: day) ?? day).timeIntervalSince1970),
                             "source_to": String(min(now.addingTimeInterval(0.001), calendar.date(byAdding: .day, value: 1, to: day) ?? now).timeIntervalSince1970),
                             "feedback_evidence": String(data: (try? JSONEncoder().encode(feedbackDates)) ?? Data(), encoding: .utf8) ?? "{}",
                             "levels": permittedLevels.map { String($0.rawValue) }.sorted().joined(separator: ",")]
            do {
                try self.ledger?.insert(.init(delivery: delivery))
                self.expireStaleLearningDeliveries()
                if self.learningFolder != nil {
                    _ = await self.learningFolder?.recordReflection(id: id, text: .init(content), at: delivery.createdAt)
                    guard self.running, self.generation == token, !Task.isCancelled,
                          self.ledger?.record(id: id)?.isPending == true, !self.learningWasErased(id) else { return }
                }
                self.learningCatchUpPending = false
                _ = self.beginSend(id: id)
            } catch { self.learningError = "Zeus couldn't save its reflection delivery." }
        }
    }
    func recordContextDeliveryReceipt(id: String) {
        guard !learningWasErased(id), let record = ledger?.record(id: id), record.delivery.kind != .reflection,
              let at = record.transportDeliveredAt ?? record.delivery.ackedAt else { return }
        emitContextDeliveryReceipt(deliveryID: id, cardID: record.delivery.cardID, sessionKey: record.delivery.sessionKey, at: at)
    }
    func emitContextDeliveryReceipt(deliveryID: String, cardID: String?, sessionKey: String, at date: Date) {
        guard running, let recorder = cards as? any LearningContextReceiptRecording,
              contextReceiptIDs.insert(cardID.map { "card:" + $0 } ?? "delivery:" + deliveryID).inserted else { return }
        let agent = sessions.first { $0.sessionKey == sessionKey }?.agent.rawValue ?? String(sessionKey.split(separator: ":").first ?? "other")
        let name = ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode"][agent] ?? "Assistant"
        let identity = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
        recorder.recordLearningContextReceipt(.init(deliveryID: deliveryID, cardID: cardID, deliveredAt: date, agent: agent,
            sessionLabel: name + (managedController.sessionKey == sessionKey ? " · Zeus" : " · Assistant"), sessionID: identity))
    }
    func recordReflectionReceipt(id: String) {
        guard !learningWasErased(id), let record = ledger?.record(id: id),
              record.delivery.ackedAt != nil || (record.delivery.meta["tmux_pointer"] == "true" && record.transportDeliveredAt != nil),
              [.reflection, .learning, .brief, .ruleTrigger].contains(record.delivery.kind), !record.delivery.content.isEmpty else { return }
        if record.delivery.kind == .brief || record.delivery.kind == .ruleTrigger {
            recordSentLearning(id: id, kind: record.delivery.kind.rawValue, text: .init(record.delivery.content), sessionKey: record.delivery.sessionKey, receivedAt: record.delivery.ackedAt)
            return
        }
        if record.delivery.kind == .learning {
            recordSentLearning(id: id, kind: record.delivery.meta["learning_kind"] ?? "moment", text: .init(record.delivery.content), sessionKey: record.delivery.meta["learning_consumed_by"] ?? record.delivery.sessionKey, receivedAt: record.delivery.ackedAt)
            if record.delivery.meta["learning_kind"] == "rating" { return }
            if let exact = learnings as? any LearningReadRecording { exact.markLearningRead(id: id) }
            else { markAcknowledgedLearningsRead() }
            return
        }
        if let journal = learningJournal {
            var query = JournalQuery(); query.limit = 100_000
            guard let items = try? journal.items(matching: query) else { return }
            guard reflectionSourcesRetained(record.delivery, items: items) else {
                reconcileReflectionEvidence(); return
            }
        }
        recordSentLearning(id: id, kind: "reflection", text: .init(record.delivery.content), sessionKey: record.delivery.sessionKey, receivedAt: record.delivery.ackedAt)
    }
    /// Acknowledgment, successful consumption, or a submitted durable pointer records the full body.
    func recordSentLearning(id: String, kind: String, text: Redacted<String>, sessionKey: String, receivedAt: Date? = nil) {
        guard !learningWasErased(id), let journal = learningJournal else { return }
        let identity = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let receiptID = "sent:" + id + ":" + identity.prefix(24)
        do {
            var query = JournalQuery(); query.kinds = [.sentToAssistant]; query.limit = 100_000
            let existing = try journal.items(matching: query).first(where: { $0.id == receiptID })
            let agent = sessions.first(where: { $0.sessionKey == sessionKey })?.agent.rawValue ?? sessionKey.split(separator: ":").first.map(String.init) ?? "other"
            let agentLabel = ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode"][agent] ?? "Assistant"
            let label = agentLabel + (managedController.sessionKey == sessionKey ? " · Zeus" : " · Assistant")
            let summary = kind == "ruleTrigger"
                ? "Sent a rule trigger: “" + String((ledger?.record(id: id)?.delivery.meta["rule_sentence"] ?? "Rule").prefix(100)) + "”"
                : Self.sentLearningSummary(kind: kind, text: text.value)
            let payload = JournalPayload(description: summary, text: text.value,
                details: ["kind": kind, "delivery_id": id, "agent": agent, "sessionLabel": label, "sessionID": identity])
            if existing == nil {
                try journal.append(.init(id: receiptID, time: receivedAt ?? clock.now, level: .activity, kind: .sentToAssistant,
                    payload: .init(payload, report: text.report)))
            }
            if kind != "rating" {
                (cards as? any LearningNoticeRecording)?.recordLearningNotice(.init(id: "n_" + id, kind: .reflection, createdAt: ledger?.record(id: id)?.delivery.createdAt ?? existing?.time ?? receivedAt ?? clock.now, summary: summary, actionTitle: "View", detail: text.value, ruleID: nil, deliveryKindName: LearningDeliveryVocabulary.title(kind: kind)), action: nil)
            }
        } catch { learningError = "Zeus couldn't record this learning receipt." }
    }
    static func sentLearningSummary(kind: String, text: String) -> String {
        if kind == "rating" { return "Sent the message preference" }
        if kind == "brief" { return "Sent the morning brief request" }
        if kind == "ruleTrigger" { return "Sent a rule trigger" }
        if kind == "reflection" { return "Sent the evening reflection" }
        if kind == "digest" { return "Sent the morning summary" }
        let moments = [("First activity today", "first activity today"), ("Back at the Mac", "back from a break"),
            ("Later start than usual", "a later start"), ("Day winding down", "day winding down")]
        return moments.first { text.hasPrefix($0.0) }.map { "Sent a note: " + $0.1 } ?? "Sent a note"
    }
    func learningForSending(_ learning: Learning) async -> Learning {
        if let saved = ledger?.record(id: learning.id), !saved.delivery.content.isEmpty {
            return .init(id: learning.id, kind: learning.kind, createdAt: learning.createdAt, text: saved.delivery.content)
        }
        let text = learning.text
        let safe = Learning(id: learning.id, kind: learning.kind, createdAt: learning.createdAt, text: text)
        guard !learningWasErased(learning.id) else { return safe }
        let files = await learningFolder?.recordLearning(safe) ?? []
        return .init(id: safe.id, kind: safe.kind, createdAt: safe.createdAt, text: Self.withLearningFiles(text + "\n" + proactiveBudgetLine, paths: files))
    }
    func recordLearningToolReceipts(_ items: [JSONValue], sessionKey: String) {
        for value in items {
            guard let data = try? ZeusJSON.encoder().encode(value), let learning = try? ZeusJSON.decoder().decode(Learning.self, from: data), !learningWasErased(learning.id) else { continue }
            // The tool result contains learningForSending output, never a newly reconstructed summary.
            recordSentLearning(id: learning.id, kind: learning.kind.rawValue, text: .init(learning.text), sessionKey: sessionKey)
            if ledger?.record(id: learning.id)?.isPending == true {
                // The actual tool consumer may differ from the originally pinned assistant.
                // Consume the queue without inventing a receipt for that original target.
                try? ledger?.update(id: learning.id) { $0.ackedAt = clock.now; $0.meta["learning_consumed_by"] = sessionKey }
            }
        }
    }
    /// Erasing source evidence also erases any retained reflection body and stops its retry, while preserving the daily tombstone.
    private func reconcileReflectionEvidence() {
        guard let journal = learningJournal, let ledger else { return }
        let reflections = ledger.records.filter { $0.delivery.kind == .reflection && !$0.delivery.content.isEmpty }
        guard !reflections.isEmpty else { return }
        do {
            var query = JournalQuery(); query.limit = 100_000
            let items = try journal.items(matching: query)
            let erased = Set(reflections.filter { !reflectionSourcesRetained($0.delivery, items: items) }.map { $0.delivery.id })
            guard !erased.isEmpty else { return }
            eraseLearningDeliveries(ids: erased)
        } catch { learningError = "Zeus couldn't reconcile deleted reflection evidence." }
    }
    private func reflectionDayKey(_ date: Date) -> String {
        let c = learningCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func scheduleLearningBoundary() {
        learningTimer?.cancel(); learningTimer = nil
        guard morningBriefSettings != nil || learningRules != nil || (learningJournal != nil && reflectionEnabled()) else { return }
        let now = clock.now
        // Minute boundaries are needed only while a timed rule exists; otherwise schedule exact idle/evening deadlines.
        var dates: [Date] = nextBriefBoundary.map { [$0] } ?? []
        if journalAnswerReceipts.values.contains(where: { $0.3 }) { dates.append(now.addingTimeInterval(60)) }
        if let boundary = (learningRules as? any RuleLifecycleStoring)?.nextOutcomeBoundary, boundary > now { dates.append(boundary) }
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
            if let card = cards.card(id: id), card.status == .open {
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
            return result(["rules": .array(rules.rules.filter { $0.status == .active || $0.status == .shadow }.map(ruleForAgent)),
                           "autonomy": .number(rules.autonomy)])
        }
        guard reflectionEnabled(), let journal = learningJournal, let redactor = learningRedactor,
              case .array(let array) = args.values["rules"], !array.isEmpty, array.count <= 3 else {
            throw ToolArgumentError("rules must contain 1–3 rule proposals; local learning must be configured.")
        }
        let token = generation, sessionID = sessions.first { $0.sessionKey == sessionKey }?.id
        let permittedLevels = journalAccessPolicy().enabledLevels
        guard !permittedLevels.isEmpty else { throw ToolArgumentError("No learning levels are enabled for reflection evidence.") }
        var query = JournalQuery(); query.limit = 100_000; query.levels = permittedLevels
        let evidenceItems = try journal.items(matching: query)
        let local = ReflectionLocalTime(calendar: learningCalendar)
        let journalDates = Dictionary(evidenceItems.map { ($0.id, $0.time) }, uniquingKeysWith: { first, _ in first })
        guard let reflection = (ledger?.records ?? []).last(where: { $0.delivery.kind == .reflection && $0.delivery.sessionKey == sessionKey && $0.discardedAt == nil && clock.now.timeIntervalSince($0.delivery.createdAt) < 86400 }) else {
            throw ToolArgumentError("Propose rules only in response to a recent reflection delivered to this session.")
        }
        let feedbackSnapshot = (try? JSONDecoder().decode([String: Double].self, from: Data(reflection.delivery.meta["feedback_evidence", default: "{}"].utf8))) ?? [:]
        let currentFeedback = reflectionFeedbackDates()
        let validFeedback = currentFeedback.filter { feedbackSnapshot[$0.key] == $0.value.timeIntervalSince1970 }
        let evidenceDates = journalDates.merging(validFeedback, uniquingKeysWith: { first, _ in first })
        let existingEvidence = Set(evidenceDates.keys)
        let reflectedEvidence = Set(reflection.delivery.meta["evidence", default: ""].split(separator: ",").map(String.init)).union(feedbackSnapshot.keys)
        var proposals: [RuleProposal] = []
        for value in array {
            let normalized = try normalizedRule(value)
            var proposal = try JSONDecoder().decode(RuleProposal.self, from: JSONEncoder().encode(normalized))
            guard proposal.evidence.allSatisfy({ existingEvidence.contains($0) && reflectedEvidence.contains($0) }) else { throw ToolArgumentError("Rule evidence must reference retained IDs included in this reflection. Invalid IDs: " + proposal.evidence.filter { !existingEvidence.contains($0) || !reflectedEvidence.contains($0) }.joined(separator: ", ")) }
            guard !proposal.sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposal.sentence.count <= 500 else { throw ToolArgumentError("Rule sentence must contain 1–500 characters.") }
            if proposal.trigger.isEvaluable || proposal.trigger.kind == "spend" {
                let days = Set(proposal.evidence.compactMap { evidenceDates[$0].map(local.dayKey) })
                let dates = proposal.evidence.map { id in "\(id) (\(evidenceDates[id].map { local.label($0) + ", " + local.dayKey($0) } ?? "unknown local day"))" }.joined(separator: ", ")
                guard proposal.evidence.count >= 2, days.count >= 2 else { throw ToolArgumentError("Evidence \(dates.isEmpty ? "is missing" : dates). An evaluable rule needs IDs from two different local days of this reflection.") }
            }
            if proposal.trigger.kind == "spend" { proposal.kind = .acts }
            proposal.confidence = min(0.7, max(0.4, proposal.confidence))
            proposal.sentence = await redactor.redact(proposal.sentence).value
            guard running, generation == token, sessions.first(where: { $0.sessionKey == sessionKey })?.id == sessionID,
                  sessionID != nil, isAdmitted(sessionKey), reflectionEnabled() else { throw CancellationError() }
            proposals.append(proposal)
        }
        // Revalidate evidence after async redaction: Delete Everything must not be undone by a late proposal.
        let retained = Set(try journal.items(matching: query).map(\.id)).union(reflectionFeedbackDates().filter { feedbackSnapshot[$0.key] == $0.value.timeIntervalSince1970 }.keys)
        guard journalAccessPolicy().enabledLevels == permittedLevels, proposals.allSatisfy({ $0.evidence.allSatisfy(retained.contains) }) else { throw ToolArgumentError("Rule evidence was deleted while processing the proposal.") }
        let added = try rules.propose(proposals, at: clock.now)
        learningContextDidChange()
        return result(["rules": .array(rules.rules.filter { rule in added.contains { $0.id == rule.id } }.map(ruleForAgent))])
    }
    private func ruleForAgent(_ rule: LearnedRule) -> JSONValue {
        guard case .object(var fields) = try? JSONValue.from(rule) else { return .null }
        fields["confidence"] = .string(rule.confidence >= 0.75 ? "Sure" : (rule.confidence >= 0.45 ? "Fairly sure" : "Unsure"))
        if rule.trigger.kind == "spend" { fields["purchase_policy"] = "Ask with the amount every time. A higher amount always needs a new question; standing rule approval never authorizes payment." }
        return .object(fields)
    }
    private func normalizedRule(_ value: JSONValue) throws -> JSONValue {
        guard case .object(var fields) = value, Set(fields.keys).isSubset(of: ["sentence", "trigger", "kind", "confidence", "evidence"]), fields["sentence"] != nil else { throw ToolArgumentError("Invalid rule proposal fields.") }
        if fields["kind"] == nil { fields["kind"] = "passive" }
        if fields["confidence"] == nil { fields["confidence"] = .number(0.6) }
        if fields["evidence"] == nil { fields["evidence"] = [] }
        var trigger: [String: JSONValue] = [:]
        if let raw = fields["trigger"] {
            guard case .object(let object) = raw, Set(object.keys).isSubset(of: ["time", "apps", "state", "kind"]) else { throw ToolArgumentError("Invalid rule trigger.") }
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
