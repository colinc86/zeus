import Foundation
import ZeusLink
import ZeusProtocol

/// Transport boundary for P3 channels and future tmux/OpenCode delivery.
/// A connector reports transport completion, never model acknowledgment.
/// Routing is passed explicitly so P4 connectors can read deliveryMethod, tmuxTarget
/// and openCodeBaseURL once those settings are available in the shared seam.
@MainActor
protocol DeliveryConnector {
    /// Whether this transport is presently usable for the target session.
    func canDeliver(to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) -> Bool
    /// Sends an already-persisted delivery. Cancellation must unblock the operation.
    func deliver(_ delivery: Delivery, to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) async throws
}

/// Claude channel transport. BridgeSession.push waits for stdout's pushWritten receipt.
@MainActor
struct ChannelDeliveryConnector: DeliveryConnector {
    func canDeliver(to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) -> Bool {
        session.agent == .claude && session.supportsChannel && bridge != nil
    }
    func deliver(_ delivery: Delivery, to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) async throws {
        guard canDeliver(to: session, bridge: bridge, routing: routing), let bridge else { throw BridgeLinkError.disconnected }
        try await (routing as? DeliveryRoutingContext)?.managedValidateDestination?()
        try await bridge.push(.init(deliveryID: delivery.id, content: delivery.content, meta: delivery.meta))
    }
}

/// A configured pane is meaningful only inside the server namespace selected with it.
/// Settings should persist this alongside tmuxTarget, including manual target edits.
@MainActor
protocol TmuxTargetRouting: AnyObject {
    var tmuxTargetSocketPath: String? { get }
}

/// Optional exact OpenCode session selection, implementable by Settings without
/// changing the existing AgentRoutingSettings seam. Never infer it from cwd/history.
@MainActor
protocol OpenCodeSessionRouting {
    func openCodeSessionID(for sessionKey: String) -> String?
}

/// Resolves Auto once per send, while forwarding mutable transport settings (including
/// Keychain credentials). Connectors can distinguish the actual assistant from a reply
/// originating in another session; nil Auto preferences are not "every session".
@MainActor
final class DeliveryRoutingContext: AgentRoutingSettings, OpenCodeSessionRouting, OpenCodeDestinationRouting, TmuxTargetRouting {
    let assistantSessionKey: String?
    let tmuxSocketPath: String?
    /// Commits a validated native destination before any prompt POST.
    var confirmOpenCodeDestination: ((OpenCodeDestination) throws -> Void)?
    /// Waiting for input does not count an attempt; an attempted paste does.
    var didMutateTmuxInput = false
    /// Durably records/clears an unsubmitted paste before mutating Terminal input.
    var confirmTmuxPaste: ((String?) throws -> Void)?
    /// Recovery may submit only the exact journaled input, never load/paste text.
    var onlySubmitRecordedTmuxPaste = false
    /// Set after Enter succeeds so clearing the journal can commit its receipt.
    var didSubmitRecordedTmuxPaste = false
    var managedMethod: DeliveryMethod?
    var managedPane: String?
    var managedValidateDestination: (() async throws -> Void)?
    var managedInputAllowed: (() -> Bool)?
    private let settings: any AgentRoutingSettings
    init(settings: any AgentRoutingSettings, assistantSessionKey: String?, tmuxSocketPath: String? = nil) {
        self.settings = settings; self.assistantSessionKey = assistantSessionKey; self.tmuxSocketPath = tmuxSocketPath
    }
    func openCodeSessionID(for sessionKey: String) -> String? {
        settings.openCodeSessionID(for: sessionKey)
    }
    func openCodeDestination(for sessionKey: String) -> OpenCodeDestination? {
        (settings as? any OpenCodeDestinationRouting)?.openCodeDestination(for: sessionKey)
    }
    var preferredAgent: AgentKind? { settings.preferredAgent }
    var deliveryMethod: DeliveryMethod { managedMethod ?? settings.deliveryMethod }
    // When no assistant is eligible, every reply must use its own bridge's pane.
    var tmuxTarget: String? { managedPane ?? (assistantSessionKey == nil ? nil : settings.tmuxTarget) }
    var tmuxTargetSocketPath: String? {
        managedPane != nil ? tmuxSocketPath : (settings as? any TmuxTargetRouting)?.tmuxTargetSocketPath
    }
    var openCodeBaseURL: URL? { settings.openCodeBaseURL }
    var openCodeServerPassword: String? { settings.openCodeServerPassword }
}
