import Foundation
import ZeusProtocol

/// Optional app-owned history pruning. Implementations must save the proposed
/// snapshot before publishing it, preserving actionable or unread cards and pending outgoing bubbles.
@MainActor
protocol CardHistoryRetaining {
    func retainHistory(keepingNewest count: Int, pendingCardIDs: Set<String>)
}

extension ZeusRuntime {
    /// Trim process-only dedup state to durable history and active work. No idle timer.
    func retainRuntimeHistory() {
        let records = ledger?.records ?? []
        let intents = responseJournal?.intents ?? []
        let pendingCards = Set((records.filter { $0.isPending } + unsaved).compactMap { $0.delivery.cardID })
            .union(intents.map { $0.cardID })
        (cards as? any CardHistoryRetaining)?.retainHistory(keepingNewest: 500, pendingCardIDs: pendingCards)
        let deliveryIDs = Set(records.map { $0.delivery.id })
            .union(sends.keys).union(intents.map { $0.deliveryID })
            .union(activityRecords.values.compactMap { $0.deliveryID })
        activityDeliveryIDs = activityDeliveryIDs.filter { deliveryIDs.contains($0.deliveryID) }
        activityEarlyAcknowledgments = activityEarlyAcknowledgments.filter { sends[$0.key] != nil }
        let retainedCards = Set(records.compactMap { $0.delivery.cardID }).union(pendingCards).union(waiters.keys).union(completedResponseIDs)
        handledResponses.formIntersection(retainedCards)
        let liveKeys = Set(sessions.map { $0.sessionKey }).union(records.filter { $0.isPending }.map { $0.delivery.sessionKey })
            .union(intents.compactMap { cards.card(id: $0.cardID)?.sessionKey })
        disconnectedAt = disconnectedAt.filter { liveKeys.contains($0.key) }
        activityTokens = activityTokens.filter { liveKeys.contains($0.key) || activityRecords[$0.key] != nil }
    }
}
