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

    init(id: String = "n_" + UUID().uuidString.prefix(8).lowercased(), kind: Kind, createdAt: Date, summary: String,
         actionTitle: String? = nil, detail: String? = nil, resolvedTitle: String? = nil) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.summary = summary
        self.actionTitle = actionTitle; self.detail = detail; self.resolvedTitle = resolvedTitle
    }
}
