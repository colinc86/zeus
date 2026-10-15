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
    var deliveryHolds: [DeliveryHold] { get }
    var managedSetupStale: ManagedSetupStaleness { get }
    var managedTemplateReplacement: ManagedTemplateReplacement? { get }
    func restartManagedAssistantForSetup()
    /// Call only after the user confirms replacing the exact snapshot's edited templates.
    func replaceEditedManagedTemplates(_ snapshot: ManagedTemplateReplacement) throws
}
