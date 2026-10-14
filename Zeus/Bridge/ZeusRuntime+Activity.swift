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
    func noteDeliveredActivity(sessionKey: String, deliveryID: String, token: UUID? = nil, sessionID: UUID? = nil) {
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
                      deadline: (earlyAck ?? clock.now).addingTimeInterval(300), deliveryID: deliveryID)
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
    func noteManagedScreenActivity() {
        guard running, managedStatus == .running(.working), let key = managedController.sessionKey,
              var record = activityRecords[key] else { return }
        if record.value.phase == .sent {
            record.value = activityValue(phase: .thinking, sessionKey: key, since: record.value.since)
        }
        record.deadline = max(record.deadline, clock.now.addingTimeInterval(300))
        activityRecords[key] = record
        refreshAssistantActivity()
    }

    /// A response post, explicit end, disconnect or discarded source invalidates late receipts.
    func endAssistantActivity(sessionKey: String) {
        activityRecords.removeValue(forKey: sessionKey)
        activityTokens[sessionKey] = UUID()
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
        activityEarlyAcknowledgments.removeAll()
        publishAssistantActivity(nil)
    }

    private func startActivity(phase: AssistantActivity.Phase, sessionKey: String, deadline: Date,
                               detail: String? = nil, progress: Double? = nil, deliveryID: String? = nil) {
        activityOrder += 1
        activityRecords[sessionKey] = ActivityRecord(value: activityValue(phase: phase, sessionKey: sessionKey,
            since: clock.now, detail: detail, progress: progress), deadline: deadline, order: activityOrder, deliveryID: deliveryID)
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
