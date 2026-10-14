// Owned by the PM. CONTRACT §9: these are the seams between the app UI (appdev) and the
// runtime that talks to agents (platform). Change only with PM sign-off.

import Foundation
import ZeusProtocol
import ZeusSprites
import ZeusDesign

/// The app's card store. Implemented by appdev (`CardStore`), driven by platform's `ZeusRuntime`.
@MainActor
protocol CardStoring: AnyObject {
    /// Adds a card and makes it visible. High-priority cards go to the front.
    func add(_ card: Card)
    /// Returns any card the store still knows about (open or in history).
    func card(id: String) -> Card?
    /// Mutates a card in place and refreshes `updatedAt`. Returns false if the card doesn't exist.
    @discardableResult
    func update(id: String, _ mutate: (inout Card) -> Void) -> Bool
    /// Marks the card dismissed and removes it from the visible stack.
    func dismiss(id: String)
    /// Set by the runtime. The store calls it exactly once per user response, on the MainActor,
    /// right after it records `card.response` and sets `status = .answered`.
    var responseHandler: ((Card, CardResponse) -> Void)? { get set }
}

/// Avatar status inputs (CONTRACT §7). Implemented by appdev, driven by the runtime.
@MainActor
protocol AvatarStatusControlling: AnyObject {
    /// Explicit agent override from `zeus_set_status`; expires after `ttl` seconds.
    func setOverride(_ state: AvatarState, detail: String?, progress: Double?, ttl: TimeInterval)
    /// `zeus_set_status` with `"auto"`.
    func clearOverride()
    /// Shows or clears the "couldn't reach agent" indicator (CONTRACT §5.6).
    func setDeliveryProblem(_ message: String?)
}

/// Character selection. Implemented by appdev (backed by settings), used by `zeus_*_character` tools.
@MainActor
protocol CharacterControlling: AnyObject {
    var availableCharacters: [SpriteCharacter] { get }
    var currentCharacterID: String { get set }
}

/// Switching color themes (T1). A later MCP tool can list and set themes through this; none does yet.
@MainActor
protocol ThemeControlling: AnyObject {
    var availableThemes: [ZeusThemeDefinition] { get }
    var currentThemeID: String { get }
    /// Selects a theme and remembers it; false for an unknown id.
    @discardableResult func setTheme(id: String) -> Bool
}

/// A live bridge connection as shown in Settings' session picker.
struct ConnectedSession: Identifiable, Equatable, Sendable {
    let id: UUID                  // bridgeID
    let sessionKey: String
    let agent: AgentKind
    let cwd: String
    let clientName: String?
    let supportsChannel: Bool
    let tmuxPane: String?
    let connectedAt: Date
    /// tmux server namespace paired with the pane; delivery metadata, never identity.
    let tmuxSocketPath: String?

    init(id: UUID, sessionKey: String, agent: AgentKind, cwd: String, clientName: String?,
         supportsChannel: Bool, tmuxPane: String?, connectedAt: Date, tmuxSocketPath: String? = nil) {
        self.id = id; self.sessionKey = sessionKey; self.agent = agent; self.cwd = cwd
        self.clientName = clientName; self.supportsChannel = supportsChannel; self.tmuxPane = tmuxPane
        self.connectedAt = connectedAt; self.tmuxSocketPath = tmuxSocketPath
    }
}

/// Outcome of sending a user-typed message to the assistant.
enum MessageSendResult: Equatable, Sendable {
    case delivered                // pushed / injected; awaiting ack
    case queued(reason: String)   // stored for redelivery or zeus_get_responses
    case failed(reason: String)   // e.g. the message could not be stored (no assistant queues instead; §10.2)
}

/// Durable runtime truth for one compose message (CONTRACT §10.2). The UI persists
/// this ID beside its bubble before sending and observes snapshots by ID, not text.
struct UserMessageDelivery: Identifiable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case queued, delivered, acked, discarded
    }
    let id: String
    let text: String
    let sessionKey: String?
    let state: State
    let reason: String?
    let createdAt: Date
    let updatedAt: Date
    /// Loaded from disk in this runtime launch; independent of the durable state.
    let recovered: Bool

    /// Allocate once, persist beside the bubble, and reuse for every retry.
    static func makeID() -> String { "d_" + UUID().uuidString.prefix(8).lowercased() }
}

/// What the UI needs from the runtime. Implemented by platform's `ZeusRuntime`.
@MainActor
protocol AgentMessaging: AnyObject {
    /// Live bridge connections, newest first. Observable by SwiftUI.
    var sessions: [ConnectedSession] { get }
    /// Sends a message the user typed in the compose box to the assistant session.
    func sendUserMessage(_ text: String) async -> MessageSendResult
    /// Idempotent send. Reusing an ID with different text fails; saved/terminal input
    /// never creates a second delivery. Unsaved failures can retry with the same ID.
    func sendUserMessage(_ text: String, deliveryID: String) async -> MessageSendResult
    /// Observable lifecycle snapshots: newest 500 records plus every pending message.
    /// Missing IDs are unknown/pruned, not proof of acknowledgment. Unsaved failures
    /// remain app-owned outgoing state. Reconcile by ID after launch and every change.
    var userMessageDeliveries: [UserMessageDelivery] { get }
    /// The current delivery problem for the warning popover (CONTRACT §10.6), or nil.
    var deliveryIssue: DeliveryIssue? { get }
    /// "Retry now": attempt every pending delivery immediately.
    func retryPendingDeliveries()
    /// "Discard": drop every pending (unacked) delivery and clear the warning.
    func discardPendingDeliveries()
    /// What an agent is doing right now, for the thread's typing indicator (CONTRACT §10.8), or nil.
    var assistantActivity: AssistantActivity? { get }
}

/// An agent producing a response (CONTRACT §10.8).
struct AssistantActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// A message or answer was delivered; no sign of the agent yet.
        case sent
        /// The session acked or called a Zeus tool since the delivery.
        case thinking
        /// The session called `zeus_set_status` with `thinking` or `working`.
        case working
    }
    let phase: Phase
    let sessionKey: String
    /// Agent display name, e.g. "Claude".
    let agentName: String
    /// From `zeus_set_status`'s `detail`, e.g. "Drafting your Q3 talk".
    let detail: String?
    /// From `zeus_set_status`'s `progress` (0…1); nil = indeterminate.
    let progress: Double?
    let since: Date
}

/// What the warning popover shows (CONTRACT §10.6).
struct DeliveryIssue: Equatable, Sendable {
    let title: String          // e.g. "Couldn't reach your assistant"
    let detail: String         // e.g. "2 replies couldn't reach Claude (~/Zeus). It disconnected 6 min ago."
    let pendingCount: Int
    let since: Date
}

extension AgentMessaging {
    // Source-compatible fallback for existing UI fakes/implementations. These have
    // no lifecycle snapshots; the UI retains its app-owned last-known outcome.
    func sendUserMessage(_ text: String, deliveryID: String) async -> MessageSendResult { await sendUserMessage(text) }
    var userMessageDeliveries: [UserMessageDelivery] { [] }
    // Defaults until P5 implements these in ZeusRuntime.
    var deliveryIssue: DeliveryIssue? { nil }
    func retryPendingDeliveries() {}
    func discardPendingDeliveries() {}
    // Default until P11 implements it in ZeusRuntime.
    var assistantActivity: AssistantActivity? { nil }
}

/// How Zeus reaches the assistant session when it can't use a channel push (CONTRACT §5.2).
enum DeliveryMethod: String, Codable, CaseIterable, Sendable {
    case channel    // Claude Code channels via the session's own bridge
    case tmux       // paste into a tmux pane (Codex, or any agent)
    case opencode   // OpenCode server HTTP API
    case polling    // queue only; the agent calls zeus_get_responses
}

/// Routing preferences from Settings. Implemented by appdev (backed by UserDefaults).
@MainActor
protocol AgentRoutingSettings: AnyObject {
    /// The designated assistant session. nil = Auto: the newest live session of `preferredAgent`
    /// (any kind if nil), preferring channel-capable sessions when several match.
    var assistantSessionKey: String? { get }
    /// Delivery method for the assistant when the target session can't take a channel push.
    var deliveryMethod: DeliveryMethod { get }
    /// tmux target pane for `.tmux` (e.g. "%3" or "main:1.0").
    var tmuxTarget: String? { get }
    /// OpenCode server base URL for `.opencode` (e.g. http://127.0.0.1:4096).
    var openCodeBaseURL: URL? { get }
    /// Basic-auth password for the OpenCode server (`OPENCODE_SERVER_PASSWORD`), stored in the Keychain.
    var openCodeServerPassword: String? { get }
    /// The Backend chosen in Settings. "Auto (newest)" picks the newest live session of this agent kind.
    var preferredAgent: AgentKind? { get }
    /// Explicit native ses… selection for this Zeus process session. nil means queue
    /// or polling, never global TUI injection or guessing a destination from cwd.
    func openCodeSessionID(for sessionKey: String) -> String?
    /// The managed assistant session's settings, or nil (CONTRACT §11).
    var managedSession: ManagedSessionConfig? { get }
}

/// The one Zeus-managed assistant session's settings (CONTRACT §11).
struct ManagedSessionConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    /// Absolute folder the agent runs in.
    var folder: String
    var agent: AgentKind
    /// `ManagedPermissionMode.id` for `agent`; nil = that agent's default (asking) mode.
    var permissionModeID: String?
    /// User-editable instructions passed on every launch (CONTRACT §11.1).
    var launchPrompt: String
    var startWhenZeusOpens: Bool
}

/// One of an agent's own permission modes, as offered in Settings (CONTRACT §11.1).
struct ManagedPermissionMode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// One line on what it still asks about.
    let detail: String
    /// True for the full-auto / "yolo" mode; Settings labels it as unrestricted.
    let isUnrestricted: Bool
    let isDefault: Bool
}

/// The managed session's state (CONTRACT §11.7).
enum ManagedSessionStatus: Equatable, Sendable {
    enum Activity: Equatable, Sendable { case idle, working, unknown }
    case off
    case starting
    case running(Activity)
    /// Waiting on a login, trust or permission prompt in the terminal; `reason` is the dialog's first line.
    case blocked(reason: String)
    /// Exited cleanly (e.g. the user typed /exit); not restarted automatically.
    case stopped
    case restarting(at: Date)
    case failed(reason: String)
}

/// Controls the managed session (CONTRACT §11). Implemented by platform's runtime, rendered by appdev.
@MainActor
protocol ManagedSessionControlling: AnyObject {
    var managedStatus: ManagedSessionStatus { get }
    /// The actual tmux session name (e.g. "zeus", or "zeus-2" on a name collision), nil when off.
    var managedTmuxSessionName: String? { get }
    /// e.g. "tmux attach -t zeus"; nil when off.
    var managedAttachCommand: String? { get }
    /// The agent's own modes, default first. Empty if the CLI isn't installed.
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode]
    /// Whether tmux and the agent CLI are installed, or a one-line install hint for what's missing.
    func managedRequirementsProblem(for agent: AgentKind) -> String?
    func startManagedSession()
    func stopManagedSession()
    func restartManagedSession()
    /// Stops, forgets the stored conversation ID and starts a fresh conversation.
    func startNewManagedConversation()
    func openManagedSessionInTerminal()
}

extension AgentRoutingSettings {
    /// nil = no managed session configured (CONTRACT §11).
    var managedSession: ManagedSessionConfig? { nil }
    var openCodeServerPassword: String? { nil }
    var preferredAgent: AgentKind? { nil }
    func openCodeSessionID(for sessionKey: String) -> String? { nil }
}
