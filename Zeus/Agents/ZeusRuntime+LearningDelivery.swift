import Foundation
import Observation
import ZeusProtocol

extension ZeusRuntime: LearningDeliveryPresenting {
    var managedSetupStale: ManagedSetupStaleness { managedController.managedSetupStale }
    var managedTemplateReplacement: ManagedTemplateReplacement? { managedController.managedTemplateReplacement }
    func requestLearningDeliveryCancellation(deliveryID: String) {
        guard let record = ledger?.record(id: deliveryID), [.learning, .reflection, .brief, .ruleTrigger].contains(record.delivery.kind),
              heldByManagedDraft(record), let cardID = managedDraftAlertCardID else { return }
        managedDraftCancellation = .init(id: UUID(), cardID: cardID, deliveryIDs: [deliveryID])
    }
    func restartManagedAssistantForSetup() { managedController.restartManagedAssistantForSetup() }
    func replaceEditedManagedTemplates(_ snapshot: ManagedTemplateReplacement) throws {
        try managedController.replaceEditedManagedTemplates(snapshot)
    }

    /// Deletion is synchronous on the main actor. Invalidates send tokens before
    /// cancellation so even a connector that completes late cannot publish a receipt.
    func eraseLearningDeliveries(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        erasedLearningDeliveryIDs.formUnion(ids)
        for id in ids {
            sendTokens.removeValue(forKey: id)
            sends.removeValue(forKey: id)?.cancel()
            deferredSends.removeValue(forKey: id)
            deliveryHoldEpisodes.removeValue(forKey: id)
        }
        do {
            try ledger?.mutateRecords { records in
                for i in records.indices where ids.contains(records[i].delivery.id) {
                    records[i].discardedAt = clock.now
                    records[i].stateUpdatedAt = clock.now
                    records[i].delivery.content = ""
                    records[i].delivery.meta.removeValue(forKey: "evidence")
                    // Leave native input alone. A discarded record is never recovered/submitted.
                    records[i].delivery.meta.removeValue(forKey: "tmux_paste_destination")
                    records[i].holdSince = nil; records[i].holdReason = nil
                }
            }
        } catch { learningError = "Zeus couldn't save the erased delivery state. Delivery is stopped for this launch." }
        refreshLearningDeliveryPresentation()
        managedController.reconsiderSettingsApplication()
    }

    func journalEvidenceDeleted(_ ids: Set<String>?) {
        if ids == nil { clearMessageRatings() }
        reflectionTask?.cancel(); reflectionTask = nil
        let records = (ledger?.records ?? []).filter { [.learning, .reflection, .brief, .ruleTrigger].contains($0.delivery.kind) }
        let erased = Set(records.filter { record in
            guard let ids else { return true }
            let evidence = Set(record.delivery.meta["evidence", default: ""].split(separator: ",").map(String.init))
            return ids.contains(record.delivery.id) || !evidence.isDisjoint(with: ids)
        }.map { $0.delivery.id })
        eraseLearningDeliveries(ids: ids == nil ? erased.union(learnings.unreadLearnings().map(\.id)) : erased)
    }

    func learningWasErased(_ id: String) -> Bool {
        erasedLearningDeliveryIDs.contains(id) || ledger?.record(id: id)?.discardedAt != nil
            || (learnings as? any LearningDeletionObserving).map { !$0.retainedLearningIDs.contains(id) && ledger?.record(id: id)?.delivery.kind == .learning && ledger?.record(id: id)?.delivery.meta["learning_kind"] != "rating" } == true
    }

    func observeLearningAvailability() {
        guard running else { return }
        let token = generation
        withObservationTracking {
            _ = learnings.learningsEnabled
            for learning in learnings.unreadLearnings() where ledger?.record(id: learning.id) == nil { notifyLearning(learning) }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.generation == token else { return }
                self.observeLearningAvailability(); self.processDueDeliveries()
            }
        }
    }

    func enqueueLearning(_ learning: Learning) {
        guard !learningWasErased(learning.id), let ledger, ledger.record(id: learning.id) == nil else { return }
        var delivery = Delivery(id: learning.id, kind: .learning, sessionKey: assistantTarget ?? "",
            content: learning.text, createdAt: learning.createdAt)
        delivery.meta["kind"] = "learning"
        delivery.meta["learning_kind"] = learning.kind.rawValue
        do {
            try ledger.insert(.init(delivery: delivery, awaitingAssistant: assistantTarget == nil ? true : nil))
            processDueDeliveries()
        } catch { learningError = "Zeus couldn't queue this learning. It remains unread for the next launch." }
    }

    /// Legacy providers expose a cumulative cursor. Advance it only over a fully
    /// acknowledged prefix, so an out-of-order ack never consumes an unseen note.
    func markAcknowledgedLearningsRead() {
        if let exact = learnings as? any LearningReadRecording {
            for learning in learnings.unreadLearnings() where ledger?.record(id: learning.id)?.delivery.ackedAt != nil { exact.markLearningRead(id: learning.id) }
            return
        }
        var last: String?
        for learning in learnings.unreadLearnings() {
            guard ledger?.record(id: learning.id)?.delivery.ackedAt != nil else { break }
            last = learning.id
        }
        if let last { learnings.markLearningsRead(through: last) }
    }

    func publishPendingLearnings(_ records: [DeliveryRecord]) {
        let next = records.filter { $0.isPending && !erasedLearningDeliveryIDs.contains($0.delivery.id) && [.learning, .reflection, .brief, .ruleTrigger].contains($0.delivery.kind) }.map { record in
            let key = record.delivery.sessionKey
            let agent = sessions.first { $0.sessionKey == key }?.agent.rawValue ?? String(key.split(separator: ":").first ?? "")
            let name = ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode"][agent] ?? "Your assistant"
            return PendingLearningDelivery(id: record.delivery.id, kind: record.delivery.kind, text: record.delivery.content,
                preparedAt: record.delivery.createdAt, sessionLabel: name + (managedController.sessionKey == key ? " · Zeus" : ""),
                learningKind: record.delivery.meta["learning_kind"].flatMap(Learning.Kind.init(rawValue:)))
        }
        if pendingLearningDeliveries != next { pendingLearningDeliveries = next }
    }

    func refreshLearningDeliveryPresentation() {
        let records = (ledger?.records ?? []).filter { $0.isPending && !learningWasErased($0.delivery.id) && $0.transportDeliveredAt == nil && [.userMessage, .learning, .reflection, .brief, .ruleTrigger].contains($0.delivery.kind) }
        let previous = deliveryHoldEpisodes
        var next: [String: DeliveryHold] = [:]
        for record in records {
            let key = record.awaitingAssistant == true ? assistantTarget : record.delivery.sessionKey
            let reason: DeliveryHold.Reason?
            if heldByManagedDraft(record) { reason = .draft }
            else if key == nil || !sessions.contains(where: { $0.sessionKey == key }) { reason = .disconnected }
            else if managedController.enabled && key == managedController.sessionKey && !managedController.canAcceptInput { reason = .busy }
            else { reason = nil }
            if let reason {
                let old = previous[record.delivery.id]
                next[record.delivery.id] = .init(deliveryID: record.delivery.id, kind: record.delivery.kind,
                    since: old.flatMap { $0.reason == reason ? $0.since : nil }
                        ?? (record.holdReason == reason.rawValue ? record.holdSince : nil) ?? clock.now, reason: reason)
            }
        }
        do {
            try ledger?.mutateRecords { saved in
                for i in saved.indices {
                    let hold = next[saved[i].delivery.id]
                    saved[i].holdSince = hold?.since; saved[i].holdReason = hold?.reason.rawValue
                }
            }
        } catch { storageProblem = "Zeus couldn’t save the delivery hold." }
        deliveryHoldEpisodes = next
        let visible = next.values.filter { clock.now.timeIntervalSince($0.since) >= 600 }.sorted { $0.since < $1.since }
        if deliveryHolds != visible { deliveryHolds = visible }
        publishPendingLearnings(ledger?.records ?? [])
        // Gate clearance is a new opportunity, not another backoff interval.
        for id in previous.keys where next[id] == nil {
            deferredSends.removeValue(forKey: id)
            _ = beginSend(id: id)
        }
    }
}
