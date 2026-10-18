import Foundation
import Observation
import ZeusProtocol
import ZeusLink
import ZeusDesign

extension ZeusRuntime {
    /// Central transport selection; a connected polling session intentionally has no push transport.
    func transport(for key: String, delivery: Delivery? = nil) -> ((any DeliveryConnector), ConnectedSession, DeliveryRoutingContext)? {
        if let delivery, learningWasErased(delivery.id) { return nil }
        if let delivery, !proactiveDeliveryAllowed(delivery) { return nil }
        if let delivery, delivery.meta["learning_kind"] == "rating",
           let first = ledger?.records.first(where: { $0.isPending && $0.delivery.meta["learning_kind"] == "rating" }), first.delivery.id != delivery.id { return nil }
        guard delivery?.kind != .learning || delivery?.meta["learning_kind"] == "rating" || learnings.learningsEnabled else { return nil }
        guard let session = sessions.first(where: { $0.sessionKey == key }) else { return nil }
        let managed = managedController.enabled && managedController.sessionKey == key
        let recoveringPaste = delivery?.meta["tmux_paste_destination"] != nil
        let nativePinned = delivery?.meta["opencode_destination_validated"] == "true"
        // An uncertain HTTP submission keeps its exact native destination. A transport
        // toggle or managed takeover cannot replay it through an untracked TUI paste.
        if nativePinned {
            guard !managed, session.agent == .opencode, routing.deliveryMethod == .opencode else { return nil }
        }
        guard managed || recoveringPaste || routing.deliveryMethod != .polling else { return nil }
        if managed && !managedController.canAcceptInput { return nil }
        let context = DeliveryRoutingContext(settings: routing, assistantSessionKey: assistantTarget,
            tmuxSocketPath: managed ? managedController.record?.pane?.socket : (bridges[key]?.hello.tmuxSocketPath ?? session.tmuxSocketPath))
        if recoveringPaste { context.managedMethod = .tmux }
        if managed {
            context.managedMethod = session.agent == .claude && managedChannelReady.contains(key)
                && !recoveringPaste && delivery?.meta["managed_channel_fallback"] != "true" ? .channel : .tmux
            context.managedPane = managedController.record?.pane?.id
            context.managedValidateDestination = { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.managedController.validateDelivery(to: key)
            }
            context.managedInputAllowed = { [weak self] in self?.managedController.canAcceptInput == true && self?.managedController.sessionKey == key }
        }
        if managed, context.deliveryMethod == .tmux, let delivery, let record = ledger?.record(id: delivery.id), heldByManagedDraft(record) { return nil }
        guard let connector = connectors.first(where: {
            if recoveringPaste, !($0 is TmuxConnector) { return false }
            if nativePinned, !($0 is OpenCodeConnector) { return false }
            if managed, $0 is ChannelDeliveryConnector, context.deliveryMethod != .channel { return false }
            if managed, $0 is OpenCodeConnector { return false }
            return $0.canDeliver(to: session, bridge: bridges[key], routing: context)
        }) else { return nil }
        return (connector, session, context)
    }

    /// Persists an attempt before transport I/O. Reconnecting bypasses the retry deadline,
    /// but never the single in-flight send or ack state. A journaled paste is a
    /// continuation of an existing mutation, not another budgeted submission.
    @discardableResult
    func beginSend(id: String) -> Task<MessageSendResult, Never>? {
        if let task = sends[id] { return task }
        guard deferredSends[id].map({ $0 <= clock.now }) ?? true else { return nil }
        deferredSends.removeValue(forKey: id)
        guard running, let ledger, let record = ledger.record(id: id), record.isPending, record.awaitingAssistant != true,
              (record.delivery.meta["tmux_paste_destination"] != nil || (record.delivery.failedAt == nil && record.delivery.attempts < 5)),
              let (connector, session, context) = transport(for: record.delivery.sessionKey, delivery: record.delivery) else { return nil }
        guard record.delivery.kind != .learning || record.delivery.meta["learning_kind"] == "rating" || learnings.learningsEnabled else { return nil }
        let recoveringPaste = record.delivery.meta["tmux_paste_destination"] != nil
        if !recoveringPaste, let recoveredAt = record.tmuxPasteRecoveredAt,
           recoveredAt.addingTimeInterval(180) > clock.now { return nil }
        if !recoveringPaste, connector is TmuxConnector, let owner = pendingPasteAhead(of: record) {
            _ = beginSend(id: owner.delivery.id)
            return nil
        }
        context.onlySubmitRecordedTmuxPaste = recoveringPaste
        if !recoveringPaste, record.delivery.meta["managed_channel_fallback"] != "true",
           let raw = record.delivery.meta["managed_channel_sent_at"], let sent = Double(raw),
           clock.now.timeIntervalSince1970 < sent + 30 { return nil }
        do {
            try ledger.update(id: id) {
                if !recoveringPaste { $0.attempts += 1 }
                $0.lastAttemptAt = clock.now
                if managedController.sessionKey == session.sessionKey, connector is ChannelDeliveryConnector {
                    $0.meta["managed_channel_sent_at"] = String(clock.now.timeIntervalSince1970)
                }
                if connector is OpenCodeConnector, $0.meta["opencode_session_id"] == nil,
                   let native = context.openCodeSessionID(for: session.sessionKey) {
                    $0.meta["opencode_session_id"] = native
                    $0.meta["opencode_created_ms"] = String(UInt64(max(0, clock.now.timeIntervalSince1970 * 1000)))
                }
            }
        } catch { storageProblem = "Couldn't save the send attempt: \(error.localizedDescription)"; refreshProblem(); return nil }
        if unsaved.isEmpty { storageProblem = nil }
        guard let saved = ledger.record(id: id) else { return nil }
        let token = generation
        let sendToken = UUID(); sendTokens[id] = sendToken
        context.confirmOpenCodeDestination = { [weak self] destination in
            guard let self, self.running, self.generation == token, self.sendTokens[id] == sendToken,
                  let current = self.ledger?.record(id: id), current.isPending else { throw CancellationError() }
            try self.ledger?.update(id: id) {
                $0.meta["opencode_session_id"] = destination.sessionID
                $0.meta["opencode_endpoint"] = destination.endpoint.absoluteString
                $0.meta["opencode_destination_validated"] = "true"
            }
        }
        context.confirmTmuxPaste = { [weak self, weak context] destination in
            guard let self, self.running, self.generation == token, self.sendTokens[id] == sendToken,
                  self.ledger?.record(id: id)?.isPending == true else { throw CancellationError() }
            try self.ledger?.updateRecord(id: id) {
                $0.delivery.meta["tmux_paste_destination"] = destination
                $0.delivery.meta.removeValue(forKey: "tmux_hidden_paste")
                if destination != nil { $0.delivery.meta["tmux_pointer"] = context?.usesTmuxPointer == true ? "true" : nil }
                if recoveringPaste && destination == nil && context?.didSubmitRecordedTmuxPaste == true {
                    $0.delivery.failedAt = nil
                    $0.tmuxPasteRecoveredAt = self.clock.now
                    $0.transportDeliveredAt = self.clock.now
                    $0.queueReason = nil; $0.stateUpdatedAt = self.clock.now
                }
            }
        }
        let bridge = bridges[session.sessionKey]
        let activityToken = activityTokens[session.sessionKey]
        let task: Task<MessageSendResult, Never> = Task { [weak self] in
            var outcome: MessageSendResult
            var postponed = false
            do {
                try Task.checkCancellation()
                guard self != nil else { return .queued(reason: "Zeus runtime stopped; the delivery remains saved.") }
                try await connector.deliver(saved.delivery, to: session, bridge: bridge, routing: context)
                outcome = .delivered
            } catch {
                if case .hidden = error as? TmuxPasteRecoveryError, let self,
                   self.generation == token, self.sendTokens[id] == sendToken,
                   self.ledger?.record(id: id)?.isPending == true {
                    do { try self.ledger?.update(id: id) { $0.meta["tmux_hidden_paste"] = "true" } }
                    catch { self.storageProblem = "Couldn't save the paste review state." }
                }
                postponed = (error as? ConnectorError)?.postponesDelivery == true
                    && self?.ledger?.record(id: id)?.delivery.meta["tmux_paste_destination"] == nil && !context.didMutateTmuxInput
                if let self, let current = self.ledger?.record(id: id), let problem = self.nativeDestinationProblem(current) {
                    outcome = .queued(reason: problem)
                } else { outcome = .queued(reason: Self.deliveryErrorDescription(error)) }
            }
            guard let self, self.generation == token, self.sendTokens[id] == sendToken else { return .queued(reason: "Delivery changed or the runtime stopped.") }
            if self.ledger?.record(id: id)?.delivery.ackedAt != nil { outcome = .delivered }
            if postponed {
                do {
                    try self.ledger?.update(id: id) {
                        $0.attempts = record.delivery.attempts; $0.lastAttemptAt = record.delivery.lastAttemptAt
                        $0.meta = record.delivery.meta
                        if $0.meta["opencode_destination_validated"] != "true" {
                            $0.meta.removeValue(forKey: "opencode_session_id")
                            $0.meta.removeValue(forKey: "opencode_created_ms")
                            $0.meta.removeValue(forKey: "opencode_endpoint")
                        }
                    }
                    self.deferredSends[id] = self.clock.now.addingTimeInterval(5)
                } catch { self.storageProblem = "Couldn't save the postponed delivery: \(error.localizedDescription)" }
            }
            self.recordUserMessageOutcome(id: id, outcome: outcome)
            if outcome == .delivered {
                if self.ledger?.record(id: id)?.delivery.meta["tmux_pointer"] == "true" {
                    do { try self.ledger?.updateRecord(id: id) { $0.transportDeliveredAt = self.clock.now } }
                    catch { self.storageProblem = "Couldn't save the pointer delivery receipt." }
                }
                self.recordReflectionReceipt(id: id)
                if self.ledger?.record(id: id)?.delivery.kind == .reply, self.ledger?.record(id: id)?.transportDeliveredAt == nil {
                    do { try self.ledger?.updateRecord(id: id) { $0.transportDeliveredAt = self.clock.now } }
                    catch { self.storageProblem = "Couldn't save the answer delivery receipt." }
                }
                self.recordContextDeliveryReceipt(id: id)
            }
            if outcome == .delivered {
                self.noteDeliveredActivity(sessionKey: session.sessionKey, deliveryID: id, token: activityToken, sessionID: session.id)
            } else { self.activityEarlyAcknowledgments.removeValue(forKey: id) }
            self.sends.removeValue(forKey: id); self.sendTokens.removeValue(forKey: id)
            self.managedController.reconsiderSettingsApplication()
            if recoveringPaste, outcome != .delivered {
                self.deferredSends[id] = self.clock.now.addingTimeInterval(5)
            }
            if self.ledger?.record(id: id)?.delivery.ackedAt == nil {
                self.markExhausted(id: id)
            }
            self.processDueDeliveries()
            return outcome
        }
        sends[id] = task
        scheduleRetry()
        return task
    }

    func markExhausted(id: String) {
        guard let ledger, let record = ledger.record(id: id), record.isPending, record.awaitingAssistant != true,
              record.delivery.meta["tmux_paste_destination"] == nil,
              record.tmuxPasteRecoveredAt.map({ $0.addingTimeInterval(180) <= clock.now }) ?? true,
              record.delivery.failedAt == nil, record.delivery.attempts >= 5 else { return }
        do { try ledger.update(id: id) { $0.failedAt = clock.now }; if unsaved.isEmpty { storageProblem = nil } }
        catch { storageProblem = "Couldn't save delivery failure: \(error.localizedDescription)" }
    }
    /// Exact 3, 6, 12, 24 minute intervals after attempts one through four.
    func retryDeadline(_ delivery: Delivery) -> Date {
        if delivery.meta["tmux_paste_destination"] != nil {
            return (delivery.lastAttemptAt ?? delivery.createdAt).addingTimeInterval(5)
        }
        if delivery.meta["managed_channel_fallback"] != "true", let raw = delivery.meta["managed_channel_sent_at"], let sent = Double(raw) {
            return Date(timeIntervalSince1970: sent + 30)
        }
        // Fallback may wait on a blocked/working screen past its deadline.
        if delivery.meta["managed_channel_fallback"] == "true", let raw = delivery.meta["managed_channel_sent_at"], let sent = Double(raw),
           delivery.lastAttemptAt.map({ $0.timeIntervalSince1970 <= sent }) ?? true { return clock.now }
        guard let attempted = delivery.lastAttemptAt else { return clock.now }
        return attempted.addingTimeInterval(180 * pow(2, Double(max(0, min(3, delivery.attempts - 1)))))
    }
    func processDueDeliveries() {
        guard running else { return }
        expireStaleLearningDeliveries()
        scheduleRatingDelivery()
        expireManagedChannels()
        if !unsaved.isEmpty, let ledger {
            for record in unsaved {
                do { try ledger.insert(record) }
                catch { storageProblem = "Couldn't save the response: \(error.localizedDescription)"; break }
            }
            unsaved.removeAll { ledger.record(id: $0.delivery.id) != nil }
            if unsaved.isEmpty { storageProblem = nil }
        }
        recoverResponses()
        retargetDeadUserMessages()
        bindWaitingUserMessages()
        refreshManagedDraftAlert()
        refreshQueueReasons()
        refreshLearningDeliveryPresentation()
        updateDisconnectedTargets()
        rerouteEarlierReplies()
        for record in ledger?.records ?? [] {
            let delivery = record.delivery
            guard record.isPending, sends[delivery.id] == nil else { continue }
            if delivery.meta["tmux_paste_destination"] != nil { _ = beginSend(id: delivery.id) }
            else if delivery.failedAt != nil { continue }
            else if delivery.attempts >= 5 { markExhausted(id: delivery.id) }
            else if retryDeadline(delivery) <= clock.now { _ = beginSend(id: delivery.id) }
        }
        retainRuntimeHistory()
        refreshProblem(); scheduleRetry()
    }
    /// Recover saved card answers after a crash or a failed ledger write. A journal
    /// entry survives until the ledger insert or synchronous stdout receipt commits.
    func recoverResponses() {
        for intent in responseJournal?.intents ?? [] {
            guard !awaitingAnswerReceipt.contains(intent.cardID) else { continue }
            if (ledger?.records ?? []).contains(where: { $0.delivery.cardID == intent.cardID }) {
                do { try responseJournal?.complete(intent.cardID) }
                catch { storageProblem = "Couldn't commit the response journal: \(error.localizedDescription)" }
            } else if let card = cards.card(id: intent.cardID), let response = card.response {
                // Remove memory-only suppression: the durable ledger is the authority.
                handledResponses.insert(card.id)
                enqueueResponse(card, response: response)
            } else if let card = cards.card(id: intent.cardID), card.status != .open {
                do { try responseJournal?.complete(intent.cardID) }
                catch { storageProblem = "Couldn't retire the response intent: \(error.localizedDescription)" }
            }
        }
    }
    /// Retarget only a proven dead agent lifetime, never a transient bridge outage.
    func retargetDeadUserMessages() {
        let dead = Set((ledger?.records ?? []).filter { record in
            (record.delivery.kind == .userMessage || record.delivery.kind == .reflection || record.delivery.kind == .learning || record.delivery.kind == .brief || record.delivery.kind == .ruleTrigger) && record.isPending && record.awaitingAssistant != true
                && record.delivery.meta["opencode_destination_validated"] != "true"
                && sends[record.delivery.id] == nil && !sessions.contains(where: { $0.sessionKey == record.delivery.sessionKey })
        }.map { $0.delivery.sessionKey }.filter(targetIsDead))
        guard !dead.isEmpty else { return }
        do {
            try ledger?.mutateRecords { records in
                for i in records.indices where (records[i].delivery.kind == .userMessage || records[i].delivery.kind == .reflection || records[i].delivery.kind == .learning || records[i].delivery.kind == .brief || records[i].delivery.kind == .ruleTrigger) && records[i].isPending
                    && records[i].awaitingAssistant != true
                    && records[i].delivery.meta["opencode_destination_validated"] != "true"
                    && sends[records[i].delivery.id] == nil
                    && dead.contains(records[i].delivery.sessionKey) {
                    records[i].delivery.sessionKey = ""; records[i].awaitingAssistant = true
                    records[i].transportDeliveredAt = nil; records[i].stateUpdatedAt = clock.now
                    records[i].queueReason = "Waiting for your current assistant."
                    records[i].delivery.meta.removeValue(forKey: "opencode_session_id")
                    records[i].delivery.meta.removeValue(forKey: "opencode_created_ms")
                    records[i].delivery.meta.removeValue(forKey: "opencode_endpoint")
                    records[i].delivery.meta.removeValue(forKey: "opencode_destination_validated")
                    records[i].delivery.attempts = 0; records[i].delivery.lastAttemptAt = nil; records[i].delivery.failedAt = nil
                }
            }
        } catch { storageProblem = "Couldn't save the message's new target: \(error.localizedDescription)" }
    }
    func scheduleRetry() {
        retryTimer?.cancel(); retryTimer = nil
        guard running else { return }
        var dates: [Date] = []
        if let deadline = managedDraftDeadline { dates.append(deadline) }
        dates += deliveryHoldEpisodes.values.map { $0.since.addingTimeInterval(600) }.filter { $0 > clock.now }
        if !(responseJournal?.intents ?? []).isEmpty && storageProblem != nil { dates.append(clock.now.addingTimeInterval(3)) }
        if !unsaved.isEmpty { dates.append(clock.now.addingTimeInterval(3)) }
        for record in ledger?.records ?? [] where record.isPending {
            let delivery = record.delivery
            if delivery.kind == .userMessage || delivery.kind == .reflection || delivery.kind == .learning || delivery.kind == .brief || delivery.kind == .ruleTrigger, record.awaitingAssistant != true, !sessions.contains(where: { $0.sessionKey == delivery.sessionKey }), delivery.sessionKey.contains("#") {
                dates.append(clock.now.addingTimeInterval(5))
            }
            if record.awaitingAssistant == true, assistantTarget != nil {
                // A failed binding transaction must retry even though no routing key exists yet.
                dates.append(clock.now.addingTimeInterval(3))
            }
            if delivery.meta["managed_channel_fallback"] != "true", let raw = delivery.meta["managed_channel_sent_at"], let sent = Double(raw) {
                dates.append(max(Date(timeIntervalSince1970: sent + 30), clock.now.addingTimeInterval(storageProblem == nil ? 0.01 : 3)))
            }
            if sends[delivery.id] == nil {
                if delivery.failedAt == nil || delivery.meta["tmux_paste_destination"] != nil,
                   transport(for: delivery.sessionKey, delivery: delivery) != nil {
                    // Avoid spinning when a durable transaction cannot be saved.
                    let due = delivery.meta["tmux_paste_destination"] == nil
                        ? max(record.tmuxPasteRecoveredAt?.addingTimeInterval(180) ?? .distantPast, retryDeadline(delivery)) : clock.now
                    // A later message has no independent deadline while a saved
                    // paste owns its pane; the owner's recovery timer wakes both.
                    if pendingPasteAhead(of: record) == nil || delivery.meta["tmux_paste_destination"] != nil {
                        dates.append(max(deferredSends[delivery.id] ?? clock.now, storageProblem == nil ? due : clock.now.addingTimeInterval(3)))
                    }
                }
                if delivery.kind == .reply, let absent = record.disconnectedAt,
                   let assistant = assistantTarget, assistant != delivery.sessionKey {
                    dates.append(max(absent.addingTimeInterval(60.001), clock.now.addingTimeInterval(storageProblem == nil ? 0 : 3)))
                }
            }
            if (!canConsume(record) || nativeDestinationProblem(record) != nil || managedQueueReason(record) != nil), delivery.createdAt.addingTimeInterval(120) >= clock.now {
                dates.append(delivery.createdAt.addingTimeInterval(120.001))
            }
        }
        for record in unsaved where !canConsume(record) && record.delivery.createdAt.addingTimeInterval(120) >= clock.now {
            dates.append(record.delivery.createdAt.addingTimeInterval(120.001))
        }
        guard let deadline = dates.min() else { return }
        let clock = self.clock
        retryTimer = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.processDueDeliveries()
        }
    }

    func acknowledge(ids: Set<String>, sessionKey: String) throws -> [String] {
        guard let ledger else { return [] }
        let acked = try ledger.acknowledge(ids: ids.filter { !learningWasErased($0) }, sessionKey: sessionKey, at: clock.now)
        if !acked.isEmpty { noteActivityAcknowledgments(acked, sessionKey: sessionKey) }
        for id in acked { recordReflectionReceipt(id: id); recordContextDeliveryReceipt(id: id) }
        retainRuntimeHistory()
        if unsaved.isEmpty { storageProblem = nil }
        refreshLearningDeliveryPresentation(); refreshProblem(); scheduleRetry()
        return acked
    }

    static func deliveryErrorDescription(_ error: any Error) -> String {
        if let recovery = error as? TmuxPasteRecoveryError { return recovery.localizedDescription }
        if let connector = error as? ConnectorError { return connector.localizedDescription }
        if let link = error as? BridgeLinkError {
            switch link {
            case .disconnected, .stopped: return ZeusRuntimeCopy.Delivery.disconnected
            case .timeout: return ZeusRuntimeCopy.Delivery.linkTimedOut
            default: return ZeusRuntimeCopy.Delivery.linkFailed
            }
        }
        if (error as? URLError)?.code == .timedOut { return ZeusRuntimeCopy.Delivery.linkTimedOut }
        return ZeusRuntimeCopy.Delivery.linkFailed
    }

    static var deliveryProblemText: String { "Couldn't reach your assistant. Zeus will keep trying." }
    static var earlierSessionPrefix: String { "(Answer to a question from an earlier session)" }

    /// Explicit selection is stable even offline; Auto follows the newest eligible live assistant.
    var assistantTarget: String? {
        if managedController.enabled { return managedController.sessionKey }
        if let selected = routing.assistantSessionKey, !targetIsDead(selected) { return selected }
        // ST1: in "Only my assistant", Auto keeps the session it adopted instead of following the newest one.
        if let admission = routing as? any AssistantAdmissionRouting, admission.onlyAssistantMayTalk {
            if let adopted = admission.adoptedAssistantSessionKey, !targetIsDead(adopted) { return adopted }
        }
        let eligible = assistantCandidates.filter { routing.preferredAgent == nil || $0.agent == routing.preferredAgent }
        return (eligible.first(where: { $0.supportsChannel }) ?? eligible.first)?.sessionKey
    }

    /// Without a native session selection, same-folder OpenCode bridges represent
    /// one ambiguous assistant; newest bridge is the polling representative.
    var assistantCandidates: [ConnectedSession] {
        var folders: Set<String> = []
        return sessions.filter { session in
            if session.agent != .opencode || routing.openCodeSessionID(for: session.sessionKey) != nil { return true }
            return folders.insert(session.cwd).inserted
        }
    }

    /// Bind previously untargeted compose input exactly once. Explicit offline choices
    /// retain their key; Auto waits for an eligible live session (including polling-only).
    /// Saving the binding before transport preserves identity and scoped acknowledgments.
    func bindWaitingUserMessages() {
        guard let assistant = assistantTarget else { return }
        do {
            try ledger?.mutateRecords { records in
                for index in records.indices where records[index].awaitingAssistant == true && records[index].isPending {
                    records[index].delivery.sessionKey = assistant
                    records[index].awaitingAssistant = nil
                    records[index].stateUpdatedAt = clock.now
                }
            }
        } catch { storageProblem = "Couldn't save the assistant target: \(error.localizedDescription)" }
    }

    /// A disconnect observed in this process applies even to an answer given much later.
    /// Older snapshots without an absence timestamp conservatively start at delivery creation.
    func updateDisconnectedTargets() {
        do {
            try ledger?.mutateRecords { records in
                for index in records.indices where records[index].isPending && records[index].delivery.kind == .reply {
                    let key = records[index].delivery.sessionKey
                    if sessions.contains(where: { $0.sessionKey == key }) { records[index].disconnectedAt = nil }
                    else if records[index].disconnectedAt == nil {
                        records[index].disconnectedAt = disconnectedAt[key] ?? records[index].delivery.createdAt
                    }
                }
            }
        } catch { storageProblem = "Couldn't save session availability: \(error.localizedDescription)" }
    }

    /// Save the new target before sending. Preserve the delivery ID, card ID and answer,
    /// and reset transport attempts so an exhausted dead session cannot poison the assistant.
    func rerouteEarlierReplies() {
        guard let assistant = assistantTarget else { return }
        do {
            try ledger?.mutateRecords { records in
                for index in records.indices {
                    let record = records[index], delivery = record.delivery
                    guard record.isPending, delivery.kind == .reply,
                          delivery.meta["opencode_destination_validated"] != "true",
                          delivery.sessionKey != assistant, sends[delivery.id] == nil,
                          let absent = record.disconnectedAt, clock.now.timeIntervalSince(absent) > 60 else { continue }
                    if delivery.meta["earlier_session"] == nil {
                        records[index].delivery.meta["earlier_session"] = delivery.sessionKey
                        records[index].delivery.content = Self.earlierSessionPrefix + " " + delivery.content
                    }
                    records[index].delivery.sessionKey = assistant
                    records[index].delivery.meta.removeValue(forKey: "opencode_session_id")
                    records[index].delivery.meta.removeValue(forKey: "opencode_created_ms")
                    records[index].delivery.meta.removeValue(forKey: "opencode_destination_validated")
                    records[index].delivery.attempts = 0
                    records[index].delivery.lastAttemptAt = nil
                    records[index].delivery.failedAt = nil
                    records[index].tmuxPasteRecoveredAt = nil
                    records[index].disconnectedAt = sessions.contains(where: { $0.sessionKey == assistant }) ? nil : clock.now
                }
            }
        } catch { storageProblem = "Couldn't save the reply's new target: \(error.localizedDescription)" }
    }

    /// "Retry now" reopens exhausted deliveries and bypasses backoff. An active send
    /// already counts as an immediate attempt and is left alone to avoid duplicate injection.
    func retryPendingDeliveries() {
        guard running else { return }
        deferredSends.removeAll()
        do {
            try ledger?.mutateRecords { records in
                for index in records.indices where records[index].isPending && sends[records[index].delivery.id] == nil {
                    records[index].delivery.attempts = 0
                    records[index].delivery.lastAttemptAt = nil
                    records[index].delivery.failedAt = nil
                    records[index].tmuxPasteRecoveredAt = nil
                }
            }
            if unsaved.isEmpty { storageProblem = nil }
            processDueDeliveries()
        } catch { storageProblem = "Couldn't save the retry: \(error.localizedDescription)" }
    }

    /// Discard deletes replies and retains terminal user-message tombstones,
    /// never a fabricated model acknowledgment.
    /// In-flight completions lose their token so they cannot resurrect discarded state.
    func discardPendingDeliveries() {
        guard running else { return }
        do {
            let ids = Set((ledger?.records ?? []).filter { $0.isPending }.map { $0.delivery.id })
            let discardedCards = Set(((ledger?.records ?? []).filter { $0.isPending } + unsaved).compactMap { $0.delivery.cardID })
            for cardID in discardedCards { try responseJournal?.complete(cardID) }
            try ledger?.mutateRecords { records in
                for index in records.indices where records[index].isPending && records[index].delivery.kind == .userMessage {
                    records[index].discardedAt = clock.now; records[index].stateUpdatedAt = clock.now
                    records[index].queueReason = nil
                }
                records.removeAll { $0.isPending && $0.delivery.kind == .reply }
            }
            unsaved.removeAll(); storageProblem = nil
            for id in ids { sendTokens.removeValue(forKey: id); sends.removeValue(forKey: id)?.cancel() }
            discardAssistantActivities(deliveryIDs: ids)
            refreshManagedDraftAlert()
            refreshProblem(); scheduleRetry()
        } catch { storageProblem = "Couldn't discard saved deliveries: \(error.localizedDescription)" }
    }

    /// Polling is reachable only for a session that can actually consume this input.
    /// An unrelated live bridge cannot clear another assistant's warning.
    func canConsume(_ record: DeliveryRecord) -> Bool {
        let key = record.awaitingAssistant == true ? assistantTarget : record.delivery.sessionKey
        guard let key else { return false }
        return sessions.contains { $0.sessionKey == key }
    }

    /// Show only exhausted deliveries, or input older than two minutes when no live
    /// bridge can consume it (polling counts as reachable). Reevaluate on time and routing.
    func refreshProblem() {
        let pending = (ledger?.records ?? []).filter { $0.isPending } + unsaved
        let problems = pending.filter { record in
            let inactiveManaged = belongsToManagedAssistant(record) && [.off, .stopped].contains(managedStatus)
                || (belongsToManagedAssistant(record) && { if case .failed = managedStatus { return true }; return false }())
            return record.delivery.meta["tmux_hidden_paste"] == "true" || record.delivery.failedAt != nil || (clock.now.timeIntervalSince(record.delivery.createdAt) > 120
                && (!canConsume(record) || nativeDestinationProblem(record) != nil || inactiveManaged))
        }
        let ids = Set(problems.map { $0.delivery.id })
        let previous = knownIssueIDs
        let oldIssue = deliveryIssue
        knownIssueIDs = ids
        if problems.isEmpty { deliveryIssue = nil }
        else {
            let failed = problems.filter { $0.delivery.failedAt != nil }.count
            let count = pending.count
            let explanation = failed > 0
                ? "Your assistant hasn't confirmed \(failed) \(failed == 1 ? "message" : "messages") after several tries."
                : "Your assistant isn't connected."
            deliveryIssue = DeliveryIssue(title: "Couldn't reach your assistant", detail: "\(explanation) \(count) \(count == 1 ? "message is" : "messages are") waiting. " + (failed > 0 ? "Retry now, or discard them." : "Zeus sends them when it's back."), pendingCount: count,
                                          since: problems.map { $0.delivery.failedAt ?? $0.delivery.createdAt.addingTimeInterval(120) }.min() ?? clock.now)
        }
        if problems.contains(where: { $0.delivery.meta["tmux_hidden_paste"] == "true" }) {
            deliveryIssue = DeliveryIssue(title: "Zeus's saved text is waiting in Terminal",
                detail: TmuxPasteRecoveryError.hidden.localizedDescription,
                pendingCount: pending.count, since: deliveryIssue?.since ?? clock.now)
        } else if problems.contains(where: { $0.delivery.meta["tmux_paste_destination"] != nil }) {
            deliveryIssue = DeliveryIssue(title: "Finishing a saved Zeus message",
                detail: "Zeus is finishing its saved message in Terminal. Your later messages are queued.",
                pendingCount: pending.count, since: deliveryIssue?.since ?? clock.now)
        } else if let native = problems.first(where: { nativeDestinationProblem($0) != nil }).flatMap(nativeDestinationProblem) {
            deliveryIssue = DeliveryIssue(title: "A saved message needs your attention", detail: native,
                pendingCount: pending.count, since: problems.map { $0.delivery.createdAt.addingTimeInterval(120) }.min() ?? clock.now)
        } else if let managed = problems.first(where: belongsToManagedAssistant), let reason = managedQueueReason(managed) {
            deliveryIssue = DeliveryIssue(title: "Messages are waiting for \(managedAgentName)", detail: reason,
                pendingCount: pending.count, since: problems.map { $0.delivery.createdAt.addingTimeInterval(120) }.min() ?? clock.now)
        } else if deliveryIssue != nil, !canRetryPendingDeliveries {
            deliveryIssue = DeliveryIssue(title: "Couldn't reach your assistant",
                detail: "Your messages are saved. Restore your assistant's connection, or discard them.",
                pendingCount: pending.count, since: deliveryIssue?.since ?? clock.now)
        }
        if deliveryIssue != nil, oldIssue != deliveryIssue || !ids.subtracting(previous).isEmpty {
            let detail = problems.contains(where: belongsToManagedAssistant) || problems.contains(where: { nativeDestinationProblem($0) != nil })
                ? deliveryIssue?.detail : Self.deliveryProblemText
            status.setDeliveryProblem(detail)
        } else if ids.isEmpty, !previous.isEmpty { status.setDeliveryProblem(nil) }
    }
    /// Observe settings changes without adding a UI→transport call to the shared seams.
    /// Existing saved deliveries retain their routing keys when the assistant selection changes.
    func observeRouting() {
        guard running else { return }
        let token = generation
        withObservationTracking {
            _ = routing.assistantSessionKey; _ = routing.preferredAgent; _ = routing.deliveryMethod
            _ = routing.managedSession
            _ = routing.tmuxTarget; _ = (routing as? any TmuxTargetRouting)?.tmuxTargetSocketPath
            _ = routing.openCodeBaseURL
            // Passwords are read only for an actual HTTP send, never to observe routing.
            // The Keychain getter is not an observable preference.

            for session in sessions {
                _ = routing.openCodeSessionID(for: session.sessionKey)
                _ = (routing as? any OpenCodeDestinationRouting)?.openCodeDestination(for: session.sessionKey)
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.generation == token else { return }
                self.managedController.configurationChanged()
                self.reconcileOwnScreenSampling()
                self.processDueDeliveries()
                self.observeRouting()
            }
        }
    }
}
