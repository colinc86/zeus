import Foundation
import ZeusProtocol

extension ZeusRuntime {
    /// Recognize the shipped raw-event request, not arbitrary reflection text.
    static func isLegacyReflection(_ delivery: Delivery) -> Bool {
        delivery.kind == .reflection && delivery.meta["source_hash"] == nil
            && delivery.content.contains("This is a redacted local summary, not a new user request.")
    }

    /// Reconcile before selecting any transport. Tombstones retain the old IDs so
    /// a late acknowledgment cannot consume a replacement request.
    func expireStaleLearningDeliveries() {
        guard let ledger else { return }
        let today = learningCalendar.startOfDay(for: clock.now)
        let cutoff = learningCalendar.date(byAdding: .day, value: -2, to: today) ?? today
        let local = ReflectionLocalTime(calendar: learningCalendar)
        func day(_ delivery: Delivery) -> String {
            (delivery.meta[delivery.kind == .brief ? "brief_day" : "reflection_day"]
                ?? local.dayKey(delivery.createdAt)).replacingOccurrences(of: "-", with: "")
        }
        let summaries = ledger.records.filter { [.brief, .reflection].contains($0.delivery.kind) }
        var discards: [String: String] = [:]
        for record in summaries where record.isPending {
            let delivery = record.delivery
            let successor = summaries.contains {
                let other = $0.delivery
                return other.kind == delivery.kind && other.id != delivery.id && !Self.isLegacyReflection(other)
                    && (day(other) > day(delivery)
                        || (day(other) == day(delivery) && other.createdAt > delivery.createdAt))
            }
            if Self.isLegacyReflection(delivery) || successor {
                discards[delivery.id] = "superseded"
            } else if day(delivery) < local.dayKey(delivery.kind == .brief ? today : cutoff).replacingOccurrences(of: "-", with: "") {
                discards[delivery.id] = "expired"
            }
        }
        guard !discards.isEmpty else { return }
        for id in discards.keys {
            erasedLearningDeliveryIDs.insert(id)
            sendTokens.removeValue(forKey: id); sends.removeValue(forKey: id)?.cancel()
            deferredSends.removeValue(forKey: id)
        }
        do {
            try ledger.discardLearningRequests(discards, at: clock.now)
        } catch {
            storageProblem = "Couldn't save the outdated requests."
            return
        }
        // The app reconciles existing lines from durable state; no headless notice is replayed.
        publishPendingLearnings(ledger.records)
    }
}
