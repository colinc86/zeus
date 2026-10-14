import Foundation
import ZeusLink
import ZeusProtocol

extension ZeusRuntime {
    struct TurnEndedLease {
        let sessionKey: String
        let responseToken: UUID?
        let activityToken: UUID?
        let generation: UUID
        let deliveryID: String?
    }

    /// Identity match/capture is synchronous. Suspending the callback cannot end
    /// a later response, a recycled PID, an explicit status or another agent.
    func prepareTurnEnded(_ event: TurnEnded) -> TurnEndedLease? {
        guard running, event.wireVersion == wireVersion, event.firedAt.isFinite,
              event.firedAt > 0, event.firedAt <= clock.now.timeIntervalSince1970 + 1,
              event.pid > 1, event.ppid > 1, !event.cwd.isEmpty, event.ancestors.count <= 16 else { return nil }
        let matching = sessions.filter { session in
            guard session.agent == event.agent, let lifetime = session.sessionKey.split(separator: "#").last,
                  let dot = lifetime.lastIndex(of: "."), let pid = Int(lifetime[..<dot]),
                  let start = UInt64(lifetime[lifetime.index(after: dot)...]), start > 0 else { return false }
            return event.ancestors.contains { $0.pid == pid && $0.startTime == start }
        }
        guard matching.count == 1, let key = matching.first?.sessionKey else { return nil }
        if event.agent == .opencode, let native = event.nativeSessionID {
            let expected = managedController.sessionKey == key ? managedController.record?.conversation?.nativeID : routing.openCodeSessionID(for: key)
            if let expected, expected != native { return nil }
        }
        if let id = event.deliveryID, let delivery = ledger?.record(id: id)?.delivery,
           delivery.sessionKey == key, (delivery.lastAttemptAt?.timeIntervalSince1970 ?? .infinity) <= event.firedAt {
            // Selective late-receipt tombstone. A newer in-flight delivery retains
            // its epoch; completing this old native input must not invalidate it.
            activityDeliveryIDs.insert(.init(sessionKey: key, deliveryID: id))
        }
        let deliveryID: String?
        if let record = activityRecords[key] {
            guard record.value.phase != .working, record.responseBeganAt.timeIntervalSince1970 <= event.firedAt,
                  event.deliveryID == nil || event.deliveryID == record.deliveryID else { return nil }
            deliveryID = record.deliveryID
        } else {
            // A fast native response may finish before the connector receipt.
            // Invalidate only an already-started, correlated send; no activity is created.
            let pending = (ledger?.records ?? []).filter {
                $0.delivery.sessionKey == key && sends[$0.delivery.id] != nil
                    && ($0.delivery.lastAttemptAt?.timeIntervalSince1970 ?? .infinity) <= event.firedAt
                    && (event.deliveryID == nil || event.deliveryID == $0.delivery.id)
            }
            let answers = answerActivityReceipts.values.filter {
                $0.sessionKey == key && $0.receivedAt.timeIntervalSince1970 <= event.firedAt
                    && (event.deliveryID == nil || event.deliveryID == $0.deliveryID)
            }
            let ids = Set(pending.map { $0.delivery.id } + answers.map(\.deliveryID))
            guard ids.count == 1 else { return nil }
            deliveryID = ids.first
        }
        return .init(sessionKey: key, responseToken: activityRecords[key]?.responseToken,
                     activityToken: activityTokens[key], generation: generation, deliveryID: deliveryID)
    }

    func finishTurnEnded(_ lease: TurnEndedLease) {
        let current = activityRecords[lease.sessionKey]
        guard running, generation == lease.generation, activityTokens[lease.sessionKey] == lease.activityToken,
              current?.responseToken == lease.responseToken
                || (lease.responseToken == nil && lease.deliveryID != nil && current?.deliveryID == lease.deliveryID),
              current?.value.phase != .working else { return }
        if let id = lease.deliveryID { activityDeliveryIDs.insert(.init(sessionKey: lease.sessionKey, deliveryID: id)) }
        endAssistantActivity(sessionKey: lease.sessionKey, invalidateReceipts: false)
    }

    func bridgeTurnEnded(_ event: TurnEnded) async {
        guard let lease = prepareTurnEnded(event) else { return }
        await Task.yield()
        finishTurnEnded(lease)
    }
}
