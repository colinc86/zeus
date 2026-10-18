import Foundation
import ZeusProtocol

extension ZeusRuntime {
    func stampLearningPolicy(_ delivery: inout Delivery, policy: LearningOutboundPolicy?) {
        guard let policy else { return }
        delivery.meta["privacy_policy"] = policy.fingerprint
    }
    func learningPolicyAllows(_ delivery: Delivery) -> Bool {
        guard let policy = outboundLearningPolicy(), delivery.kind == .brief || delivery.kind == .reflection
                || (delivery.kind == .learning && delivery.meta["learning_kind"] == "digest") else { return true }
        return delivery.meta["privacy_policy"] == policy.fingerprint
    }
    func reconcileOutboundLearningPolicy() {
        (learnings as? any LearningDigestPreparing)?.prepareDigestsForCurrentPolicy()
        let stale = Set((ledger?.records ?? []).filter { $0.isPending && !learningPolicyAllows($0.delivery) }.map { $0.delivery.id })
        if !stale.isEmpty { reflectionTask?.cancel(); eraseLearningDeliveries(ids: stale) }
    }
}
