import Foundation
import ZeusProtocol

extension ZeusRuntime {
    /// Old requests are no longer useful. A discard receipt never claims delivery
    /// or acknowledgment, and a paste already in Terminal is left untouched.
    func expireStaleLearningDeliveries() {
        guard let ledger else { return }
        let today = learningCalendar.startOfDay(for: clock.now)
        let cutoff = learningCalendar.date(byAdding: .day, value: -2, to: today) ?? today
        let local = ReflectionLocalTime(calendar: learningCalendar)
        let expired = ledger.records.filter { record in
            guard record.isPending else { return false }
            if record.delivery.kind == .brief {
                return record.delivery.meta["brief_day"].map { $0 < proactiveDay(today) }
                    ?? (record.delivery.createdAt < today)
            }
            if record.delivery.kind == .reflection {
                return record.delivery.meta["reflection_day"].map { $0.replacingOccurrences(of: "-", with: "") < local.dayKey(cutoff).replacingOccurrences(of: "-", with: "") }
                    ?? (record.delivery.createdAt < cutoff)
            }
            return false
        }
        for record in expired {
            let id = record.delivery.id
            erasedLearningDeliveryIDs.insert(id)
            sendTokens.removeValue(forKey: id); sends.removeValue(forKey: id)?.cancel()
            deferredSends.removeValue(forKey: id)
            do {
                try ledger.updateRecord(id: id) {
                    $0.discardedAt = clock.now; $0.stateUpdatedAt = clock.now
                    $0.queueReason = "Not sent: this request is out of date."
                    $0.delivery.meta["discard_reason"] = "expired"
                    $0.delivery.meta.removeValue(forKey: "tmux_paste_destination")
                }
            } catch { storageProblem = "Couldn't save the expired request." }
        }
        for record in ledger.records where record.delivery.meta["discard_reason"] == "expired" && record.transportDeliveredAt == nil {
            let summary = record.delivery.kind == .brief
                ? "Not sent: the morning passed before your assistant could read this brief."
                : "Not sent: the day passed before your assistant could read this reflection."
            (cards as? any LearningNoticeRecording)?.recordLearningNotice(.init(id: "n_" + record.delivery.id,
                kind: .reflection, createdAt: record.discardedAt ?? clock.now,
                summary: summary, actionTitle: "View",
                detail: record.delivery.content, ruleID: nil), action: nil)
        }
    }
}
