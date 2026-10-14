import Foundation

/// Optional UI capability; the shared managed-session seam remains source compatible.
/// Recovery and action availability describe runtime state, never localized error text.
@MainActor
protocol ManagedPresentationProviding: AnyObject {
    var managedNeedsNewConversation: Bool { get }
    var managedHasLaunched: Bool { get }
    var canRetryPendingDeliveries: Bool { get }
}

extension ZeusRuntime: ManagedPresentationProviding {
    var managedNeedsNewConversation: Bool { managedController.recoveryRequirement == .newConversation }
    var managedHasLaunched: Bool { managedController.hasLaunched }
    /// A retry can bypass backoff, but cannot create a connection or unblock a pane.
    var canRetryPendingDeliveries: Bool {
        guard running else { return false }
        return (ledger?.records ?? []).contains { record in
            guard record.isPending, sends[record.delivery.id] == nil,
                  let key = record.awaitingAssistant == true ? assistantTarget : record.delivery.sessionKey,
                  let (connector, session, context) = transport(for: key, delivery: record.delivery) else { return false }
            if record.delivery.meta["opencode_destination_validated"] == "true" {
                guard let endpoint = record.delivery.meta["opencode_endpoint"].flatMap(URL.init(string:)),
                      let id = record.delivery.meta["opencode_session_id"],
                      let pin = OpenCodeDestination(sessionID: id, endpoint: endpoint),
                      pin.endpoint == routing.openCodeBaseURL.flatMap(OpenCodeDestination.canonicalEndpoint) else { return false }
            }
            if connector is OpenCodeConnector {
                guard let current = routing.openCodeBaseURL.flatMap(OpenCodeDestination.canonicalEndpoint) else { return false }
                if record.delivery.meta["opencode_destination_validated"] != "true" {
                    guard let selection = context.openCodeDestination(for: key), selection.endpoint == current else { return false }
                }
            }
            if let tmux = connector as? TmuxConnector { return tmux.canRetryDelivery(to: session, bridge: bridges[key], routing: context) }
            return true
        }
    }
}
