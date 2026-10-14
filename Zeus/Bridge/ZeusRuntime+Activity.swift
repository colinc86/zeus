import Foundation
import ZeusProtocol

extension ZeusRuntime {
    struct ActivityDeliveryKey: Hashable {
        let sessionKey: String
        let deliveryID: String
    }

    struct ActivityRecord {
        var value: AssistantActivity
        var deadline: Date
        let order: Int
        var deliveryID: String?
        /// Last completed native Claude turn before this response started. Not persisted or exposed to agents.
        var managedCompletionAtStart: String?
        /// Distinguishes consecutive responses even when their delivery receipts share an invalidation epoch.
        var responseToken = UUID()
        /// Input started before transport/result receipt; a fast Stop hook can precede that receipt.
        var responseBeganAt: Date
    }

    /// Tool traffic advances an existing response; it never starts or revives one.
    /// Working keeps its explicit TTL; ordinary tool traffic cannot extend that override.
    func noteAgentActivity(sessionKey: String) {
        guard running, sessions.contains(where: { $0.sessionKey == sessionKey }) else { return }
        expireActivityRecords()
        if var record = activityRecords[sessionKey] {
            if record.value.phase != .working {
                record.value = activityValue(phase: .thinking, sessionKey: sessionKey, since: record.value.since)
                record.deadline = clock.now.addingTimeInterval(300)
                activityRecords[sessionKey] = record
            }
        }
        refreshAssistantActivity()
    }

    /// Called only after a successful connector receipt or an answered synchronous ask.
    /// A retry of the same delivery never resets phase, start ordering or the stale deadline.
    func noteDeliveredActivity(sessionKey: String, deliveryID: String, token: UUID? = nil, sessionID: UUID? = nil, inputStartedAt: Date? = nil) {
        let earlyAck = activityEarlyAcknowledgments.removeValue(forKey: deliveryID)
        guard running, let session = sessions.first(where: { $0.sessionKey == sessionKey }),
              sessionID == nil || session.id == sessionID,
              activityDeliveryIDs.insert(.init(sessionKey: sessionKey, deliveryID: deliveryID)).inserted else { return }
        expireActivityRecords()
        if let token, activityTokens[sessionKey] != token {
            // A post/end or explicit working status superseded this in-flight receipt.
            // An ack alone never changes this token: its delivery-specific evidence
            // selects .thinking below, without reviving a completed response.
            if activityRecords[sessionKey]?.deliveryID == nil { activityRecords[sessionKey]?.deliveryID = deliveryID }
            refreshAssistantActivity()
            return
        }
        startActivity(phase: earlyAck == nil ? .sent : .thinking, sessionKey: sessionKey,
                      deadline: (earlyAck ?? clock.now).addingTimeInterval(300), deliveryID: deliveryID,
                      inputStartedAt: inputStartedAt ?? ledger?.record(id: deliveryID)?.delivery.lastAttemptAt)
        refreshAssistantActivity()
    }

    /// Remember only acknowledged inputs whose connector receipt is still in flight.
    /// Durable ack matching already scoped these IDs to the calling session.
    func noteActivityAcknowledgments(_ ids: [String], sessionKey: String) {
        for id in ids where sends[id] != nil && !activityDeliveryIDs.contains(.init(sessionKey: sessionKey, deliveryID: id)) {
            activityEarlyAcknowledgments[id] = clock.now
        }
        noteAgentActivity(sessionKey: sessionKey)
    }

    func noteWorkingActivity(sessionKey: String, detail: String?, progress: Double?, ttl: TimeInterval) {
        guard running, sessions.contains(where: { $0.sessionKey == sessionKey }) else { return }
        expireActivityRecords()
        activityTokens[sessionKey] = UUID()
        if var record = activityRecords[sessionKey] {
            record.value = activityValue(phase: .working, sessionKey: sessionKey, since: record.value.since,
                                         detail: detail, progress: progress)
            record.deadline = clock.now.addingTimeInterval(ttl)
            activityRecords[sessionKey] = record
        } else {
            startActivity(phase: .working, sessionKey: sessionKey, deadline: clock.now.addingTimeInterval(ttl),
                          detail: detail, progress: progress)
        }
        refreshAssistantActivity()
    }

    /// Screen evidence extends only an existing managed response. It cannot revive
    /// a row ended by zeus_say, an ack race, or a completed/dropped delivery.
    /// A positive idle screen ends the row once the response has visibly run (a "working" screen was seen) or
    /// after 20 s, because an agent that finishes its turn without `zeus_say` would otherwise keep Zeus
    /// "thinking" for the whole five-minute stale window (user report, 2026-10-14). Idle right after delivery,
    /// before the agent has even started, is not treated as finished.
    static let managedIdleEndsActivityAfter: TimeInterval = 20
    func noteManagedScreenActivity() {
        guard running, let key = managedController.sessionKey, var record = activityRecords[key] else { return }
        switch managedStatus {
        case .running(.working):
            activityWorkingSeen.insert(key)
            if record.value.phase == .sent {
                record.value = activityValue(phase: .thinking, sessionKey: key, since: record.value.since)
            }
            // An explicit working status owns its TTL. Screen evidence only refreshes the implicit response lease.
            if record.value.phase != .working { record.deadline = max(record.deadline, clock.now.addingTimeInterval(300)) }
            activityRecords[key] = record
            refreshAssistantActivity()
        case .running(.idle):
            guard record.value.phase != .working,
                  activityWorkingSeen.contains(key)
                    || managedTurnCompleted(since: record, sessionKey: key)
                    || managedNativeDeliveryCompleted(record, sessionKey: key)
                    || clock.now.timeIntervalSince(record.value.since) >= Self.managedIdleEndsActivityAfter else { return }
            endAssistantActivity(sessionKey: key)
        default:
            return
        }
    }

    /// A short Claude turn can begin and end between the three-second samples. A *new* native completion footer,
    /// attached to its user turn and followed by a positive idle sample, is completion evidence even then.
    /// Other agents and unrecognized screens retain the conservative working/grace rules.
    private func managedTurnCompleted(since record: ActivityRecord, sessionKey: String) -> Bool {
        guard managedController.sessionKey == sessionKey, let sample = managedController.latestInputSample,
              sample.agent == .claude, sample.capturedAt >= record.value.since, sample.classification == .idle,
              let completed = Self.claudeCompletedTurn(sample.snapshot) else { return false }
        return completed != record.managedCompletionAtStart
    }

    nonisolated static func claudeCompletedTurn(_ snapshot: ManagedPaneSnapshot) -> String? {
        let lines = snapshot.plainLines
        // Native Claude 2.1.299: "✻ Cogitated for 0s · done 2:10 PM". Keep columns: indented tool/model/user
        // content is not the native footer. The preceding user prompt scopes identical same-minute footers.
        guard let end = lines.lastIndex(where: { $0.hasPrefix("✻ ") && $0.contains(" for ") && $0.contains(" · done ") }),
              let start = lines[..<end].lastIndex(where: { $0.hasPrefix("❯ ") && !$0.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        // A cron turn has its own native start without a user prompt. Its footer must not be attached to
        // an older user delivery (PC1's real scheduled-idle capture). A later user prompt resets this scope.
        guard !lines[start..<end].contains(where: { $0.hasPrefix("✻ Running scheduled task") }) else { return nil }
        return lines[start...end].joined(separator: "\n")
    }

    /// A complete native turn can fall between monitor samples. Only the same
    /// delivered ID in history, its native completion and a fresh positive idle
    /// sample can release it early. Explicit statuses continue to own their TTL.
    private func managedNativeDeliveryCompleted(_ record: ActivityRecord, sessionKey: String) -> Bool {
        guard managedController.sessionKey == sessionKey, let id = record.deliveryID,
              let sample = managedController.latestInputSample, sample.capturedAt >= record.value.since,
              sample.classification == .idle else { return false }
        return ManagedTurnCompletion.deliveryID(in: sample.snapshot, agent: sample.agent) == id
    }

    /// A response post, explicit end, disconnect or discarded source invalidates late receipts.
    func endAssistantActivity(sessionKey: String, invalidateReceipts: Bool = true) {
        activityRecords.removeValue(forKey: sessionKey)
        activityWorkingSeen.remove(sessionKey)
        if invalidateReceipts { activityTokens[sessionKey] = UUID() }
        refreshAssistantActivity()
    }

    func discardAssistantActivities(deliveryIDs: Set<String>) {
        for id in deliveryIDs { activityEarlyAcknowledgments.removeValue(forKey: id) }
        for (key, record) in activityRecords where record.deliveryID.map(deliveryIDs.contains) == true {
            activityRecords.removeValue(forKey: key)
            activityTokens[key] = UUID()
        }
        refreshAssistantActivity()
    }

    func resetAssistantActivity() {
        activityTimer?.cancel(); activityTimer = nil
        activityRecords.removeAll(); activityTokens.removeAll(); activityDeliveryIDs.removeAll()
        activityEarlyAcknowledgments.removeAll(); activityWorkingSeen.removeAll()
        publishAssistantActivity(nil)
    }

    private func startActivity(phase: AssistantActivity.Phase, sessionKey: String, deadline: Date,
                               detail: String? = nil, progress: Double? = nil, deliveryID: String? = nil, inputStartedAt: Date? = nil) {
        activityOrder += 1
        activityWorkingSeen.remove(sessionKey)
        activityRecords[sessionKey] = ActivityRecord(value: activityValue(phase: phase, sessionKey: sessionKey,
            since: clock.now, detail: detail, progress: progress), deadline: deadline, order: activityOrder, deliveryID: deliveryID,
            managedCompletionAtStart: managedController.sessionKey == sessionKey
                ? managedController.latestInputSample.flatMap { $0.agent == .claude ? Self.claudeCompletedTurn($0.snapshot) : nil } : nil,
            responseBeganAt: inputStartedAt ?? clock.now)
    }

    private func activityValue(phase: AssistantActivity.Phase, sessionKey: String, since: Date,
                               detail: String? = nil, progress: Double? = nil) -> AssistantActivity {
        let agent = sessions.first { $0.sessionKey == sessionKey }?.agent ?? .other
        let name: String = switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .other: "Agent"
        }
        return AssistantActivity(phase: phase, sessionKey: sessionKey, agentName: name, detail: detail, progress: progress, since: since)
    }

    private func expireActivityRecords() {
        for (key, record) in activityRecords where record.deadline <= clock.now {
            activityRecords.removeValue(forKey: key)
            activityTokens[key] = UUID()
        }
    }

    /// One sleep for the nearest stale/TTL boundary; no periodic idle polling or clock publication.
    private func refreshAssistantActivity() {
        expireActivityRecords()
        publishAssistantActivity(activityRecords.values.max { $0.order < $1.order }?.value)
        activityTimer?.cancel(); activityTimer = nil
        guard running, let deadline = activityRecords.values.map(\.deadline).min() else { return }
        let clock = self.clock, token = generation
        // ttl_seconds is finite but unbounded. Avoid overflowing Swift Duration for
        // a very long explicit TTL; keep its actual expiry, using daily checkpoints.
        let wake = min(deadline, clock.now.addingTimeInterval(86_400))
        activityTimer = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: wake) } catch { return }
            guard !Task.isCancelled, let self, self.running, self.generation == token else { return }
            self.refreshAssistantActivity()
        }
    }
}
