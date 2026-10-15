import Foundation

/// A quiet, app-owned line in the conversation: "Sent your daily summary · View" (L1, CONTRACT §13). Not a bubble:
/// it never badges, peeks, types out or plays a sound. Persisted with the history; an action's closure is not.
struct ThreadNotice: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A digest or moment sent to the assistant; the action shows `detail`, the exact text sent.
        case learning
        /// Reserved for CONTRACT §12's assistant-made changes (AC2), so both share one line style.
        case appChange
        /// An installed CLI update; restart is always an explicit, safe-moment action.
        case agentUpdate
        /// ST1: who may talk to Zeus ("Another session tried to reach Zeus: …", "Talking to …"). Two actions at most.
        case admission
    }
    static let keep = 200

    var id: String
    var kind: Kind
    var createdAt: Date
    /// "Sent your daily summary".
    var summary: String
    /// "View"; nil for no action.
    var actionTitle: String?
    /// What "View" shows.
    var detail: String?
    /// Replaces the action once it's done, e.g. "Undone".
    var resolvedTitle: String?
    /// A second plain action after the first ("Ignore"); admission lines only.
    var secondaryTitle: String?
    /// Durable edge bookkeeping, only for agent-update lines; hidden from the conversation copy.
    var isAgentUpdateCurrent: Bool?

    init(id: String = "n_" + UUID().uuidString.prefix(8).lowercased(), kind: Kind, createdAt: Date, summary: String,
         actionTitle: String? = nil, detail: String? = nil, resolvedTitle: String? = nil, isAgentUpdateCurrent: Bool? = nil,
         secondaryTitle: String? = nil) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.summary = summary
        self.actionTitle = actionTitle; self.detail = detail; self.resolvedTitle = resolvedTitle
        self.isAgentUpdateCurrent = isAgentUpdateCurrent; self.secondaryTitle = secondaryTitle
    }
}
