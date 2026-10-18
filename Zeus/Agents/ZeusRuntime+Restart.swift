import Foundation
import ZeusProtocol

extension ZeusRuntime {
    /// A bridge check-in proves this process belongs to the resumed conversation.
    /// The launch outbox is consumed only after a durable, idempotent ledger insert.
    func enqueueManagedRestartNotices() {
        guard running, let ledger, let key = managedController.sessionKey,
              sessions.contains(where: { $0.sessionKey == key }),
              let conversation = managedController.record?.conversation else { return }
        // A queued notice belongs to the native conversation, not the old process.
        // Never retarget one into a new conversation or an unrelated connected agent.
        let moved = ledger.records.filter { $0.delivery.kind == .restart && $0.isPending && $0.delivery.sessionKey != key }
        if !moved.isEmpty {
            for record in moved {
                sendTokens.removeValue(forKey: record.delivery.id)
                sends.removeValue(forKey: record.delivery.id)?.cancel()
                deferredSends.removeValue(forKey: record.delivery.id)
            }
            do {
                let ids = Set(moved.map { $0.delivery.id })
                try ledger.mutateRecords { records in
                    for i in records.indices where ids.contains(records[i].delivery.id) {
                        if records[i].delivery.meta["managed_conversation"] != conversation.nonce {
                            records[i].discardedAt = clock.now
                        } else {
                            records[i].delivery.sessionKey = key
                            records[i].delivery.attempts = 0; records[i].delivery.lastAttemptAt = nil; records[i].delivery.failedAt = nil
                            records[i].delivery.meta = ["kind": "restart", "managed_conversation": conversation.nonce]
                            records[i].transportDeliveredAt = nil; records[i].tmuxPasteRecoveredAt = nil
                        }
                    }
                }
            } catch { storageProblem = "Couldn't save the restart notice destination: \(error.localizedDescription)"; return }
        }
        for notice in managedController.record?.restartNotices ?? [] where notice.conversationID == conversation.nonce {
            do {
                if ledger.record(id: notice.id) == nil {
                    let formatter = DateFormatter()
                    formatter.calendar = learningCalendar; formatter.timeZone = learningCalendar.timeZone
                    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm"
                    let reason: String
                    switch notice.reason {
                    case "app update": reason = "after an app update"
                    case "crash recovery": reason = "after a crash"
                    case "settings change": reason = "to apply a settings change"
                    case "update": reason = "to use new tools and instructions"
                    default: reason = "because you pressed Restart Assistant"
                    }
                    let text = "Zeus restarted you at \(formatter.string(from: notice.time)) \(reason). Timers and scheduled checks you set before the restart are gone. Check what you had planned and set it again. Then zeus_ack."
                    let delivery = Delivery(id: notice.id, kind: .restart, sessionKey: key, content: text, meta: ["kind": "restart", "managed_conversation": conversation.nonce], createdAt: notice.time)
                    try ledger.insert(.init(delivery: delivery))
                }
                try managedController.consumeRestartNotice(id: notice.id)
            } catch { storageProblem = "Couldn't queue the assistant restart notice: \(error.localizedDescription)" }
        }
    }
}
