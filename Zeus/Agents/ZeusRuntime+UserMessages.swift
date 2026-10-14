import Foundation

extension ZeusRuntime {
    func userMessageText(_ record: DeliveryRecord) -> String {
        if let text = record.userText { return text }
        let prefix = "Message from the user: "
        return record.delivery.content.hasPrefix(prefix) ? String(record.delivery.content.dropFirst(prefix.count)) : record.delivery.content
    }

    /// Observation is published only by the ledger's committed snapshot callback.
    func publishUserMessageDeliveries(_ records: [DeliveryRecord]) {
        let messages = records.filter { $0.delivery.kind == .userMessage }
        recoveredUserMessageIDs.formIntersection(messages.map { $0.delivery.id })
        let next = messages.map { record in
            let delivery = record.delivery
            let state: UserMessageDelivery.State
            if record.discardedAt != nil { state = .discarded }
            else if delivery.ackedAt != nil { state = .acked }
            else if delivery.failedAt != nil { state = .queued }
            else { state = record.transportDeliveredAt == nil ? .queued : .delivered }
            let reason: String? = state == .queued
                ? (delivery.meta["tmux_paste_destination"] != nil ? "Finishing Zeus's saved message in Terminal."
                    : delivery.failedAt == nil ? record.queueReason ?? "Waiting for your assistant." : "Your assistant hasn't confirmed this after several tries. Retry when it's ready.") : nil
            return UserMessageDelivery(id: delivery.id, text: userMessageText(record),
                sessionKey: delivery.sessionKey.isEmpty ? nil : delivery.sessionKey,
                state: state, reason: reason, createdAt: delivery.createdAt,
                updatedAt: record.stateUpdatedAt ?? delivery.ackedAt ?? delivery.failedAt ?? delivery.createdAt,
                recovered: recoveredUserMessageIDs.contains(delivery.id))
        }
        setUserMessageDeliveries(next)
    }

    /// A successful write isn't an ack. Never overwrite an ack/discard that raced
    /// with transport, and never publish a lifecycle transition before it is durable.
    func recordUserMessageOutcome(id: String, outcome: MessageSendResult) {
        guard let ledger, let record = ledger.record(id: id), record.delivery.kind == .userMessage, record.isPending else { return }
        do {
            try ledger.updateRecord(id: id) {
                switch outcome {
                case .delivered: $0.transportDeliveredAt = clock.now; $0.queueReason = nil
                case .queued(let reason), .failed(let reason): $0.queueReason = reason
                }
                $0.stateUpdatedAt = clock.now
            }
        } catch { storageProblem = "Couldn't save the delivery receipt: \(error.localizedDescription)" }
    }
}
