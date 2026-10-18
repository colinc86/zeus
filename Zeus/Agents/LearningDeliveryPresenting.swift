import Foundation
import ZeusProtocol

/// An assistant-bound item held for ten minutes. `since` is the start of the
/// continuous hold, not the time the notice became visible.
struct DeliveryHold: Equatable, Sendable, Identifiable {
    enum Reason: String, Sendable { case draft, busy, disconnected, olderSetup }
    var id: String { deliveryID }
    let deliveryID: String
    let kind: Delivery.Kind
    let since: Date
    let reason: Reason
}

struct PendingLearningDelivery: Equatable, Sendable, Identifiable {
    let id: String
    let kind: Delivery.Kind
    let text: String
    let preparedAt: Date
    let sessionLabel: String
    var learningKind: Learning.Kind? = nil
    var deliveryKindName: String? = nil
    var isMessagePreference = false
}

/// Retained non-delivery evidence; erasure and explicit cancellation are never included.
struct DiscardedLearningDelivery: Equatable, Sendable, Identifiable {
    enum Reason: String, Sendable { case expired, superseded }
    let id: String
    let kind: Delivery.Kind
    let text: String
    let preparedAt: Date
    let discardedAt: Date
    let reason: Reason
    let queueReason: String
    let deliveryKindName: String

    static func caption(kind: Delivery.Kind, reason: Reason) -> String {
        switch (kind, reason) {
        case (.brief, .superseded): "Replaced by today's brief request"
        case (_, .superseded): "Replaced by a newer reflection"
        case (.brief, .expired): "Not sent: the morning passed before your assistant could read this brief."
        case (_, .expired): "Not sent: the day passed before your assistant could read this reflection."
        }
    }
}

/// The same nouns describe requests, receipts and their exact-text viewer pages.
enum LearningDeliveryVocabulary {
    static func title(kind: String) -> String? {
        switch kind {
        case "digest": "Morning summary"
        case "reflection": "Evening reflection"
        case "brief": "Morning brief request"
        case "moment": "Note"
        case "ruleTrigger": "Rule trigger"
        case "rating": "Message preference"
        default: nil
        }
    }
    static func title(kind: Delivery.Kind, learningKind: String? = nil) -> String {
        title(kind: kind == .learning ? learningKind ?? "digest" : kind.rawValue) ?? "Note"
    }
}

struct ManagedSetupStaleness: Equatable, Sendable {
    var tools = false
    var template = false
    var templateEdited = false
}

/// Snapshot-scoped explicit replacement: a changed folder/file invalidates confirmation.
struct ManagedTemplateReplacement: Equatable, Sendable {
    let folder: String
    let hashes: [String: String]
}

/// Optional observable runtime capability. Reading these properties participates
/// in Observation. Sent receipts remain in the journal, never synthesized from pending items.
@MainActor protocol LearningDeliveryPresenting: AnyObject {
    var pendingLearningDeliveries: [PendingLearningDelivery] { get }
    var discardedLearningDeliveries: [DiscardedLearningDelivery] { get }
    var deliveryHolds: [DeliveryHold] { get }
    var managedSetupStale: ManagedSetupStaleness { get }
    var managedTemplateReplacement: ManagedTemplateReplacement? { get }
    func requestLearningDeliveryCancellation(deliveryID: String)
    func restartManagedAssistantForSetup()
    /// Call only after the user confirms replacing the exact snapshot's edited templates.
    func replaceEditedManagedTemplates(_ snapshot: ManagedTemplateReplacement) throws
}

/// Exact consumption prevents an out-of-order delivery acknowledgment from
/// marking an earlier, unseen learning read. Legacy providers retain prefix behavior.
@MainActor protocol LearningReadRecording: AnyObject {
    func markLearningRead(id: String)
}

extension LearningDeliveryPresenting {
    var discardedLearningDeliveries: [DiscardedLearningDelivery] { [] }
}
