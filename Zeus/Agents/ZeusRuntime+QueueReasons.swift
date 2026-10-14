import Foundation
import ZeusDesign
import ZeusProtocol

extension ZeusRuntime {
    /// Finish a previous input mutation before another message can acquire its pane.
    func pendingPasteAhead(of record: DeliveryRecord) -> DeliveryRecord? {
        (ledger?.records ?? []).first { $0.isPending && $0.delivery.id != record.delivery.id
            && $0.delivery.sessionKey == record.delivery.sessionKey && $0.delivery.meta["tmux_paste_destination"] != nil }
    }
    var managedAgentName: String {
        switch managedController.record?.conversation?.agent ?? managedController.configuration()?.agent ?? routing.managedSession?.agent ?? .other {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .other: "Your assistant"
        }
    }
    func belongsToManagedAssistant(_ record: DeliveryRecord) -> Bool {
        managedController.enabled && record.delivery.kind == .userMessage
            && (record.awaitingAssistant == true || record.delivery.sessionKey == managedController.sessionKey
                || record.delivery.sessionKey == managedController.record?.confirmedSessionKey)
    }
    /// A queue caption describes the current gate, not a past connection failure.
    func managedQueueReason(_ record: DeliveryRecord) -> String? {
        guard belongsToManagedAssistant(record) else { return nil }
        let agent = managedAgentName
        switch managedStatus {
        case .starting, .restarting: return "Waiting for \(agent) to start."
        case .blocked: return "Waiting until you answer \(agent) in Terminal."
        case .running(.working): return "Waiting for \(agent) to finish what it's doing."
        case .running(.unknown): return "Waiting for \(agent)'s Terminal to be ready."
        case .stopped: return "\(agent) is stopped. Start it to send this."
        case .off: return "\(agent) isn't running. Start it to send this."
        case .failed:
            return managedNeedsNewConversation
                ? "Start a new conversation with \(agent) to send this."
                : "\(agent) isn't running. Start it to send this."
        case .running(.idle):
            return canConsume(record) ? nil : "Waiting for \(agent) to connect to Zeus."
        }
    }
    /// A live bridge cannot consume a message whose exact HTTP destination is unavailable.
    func nativeDestinationProblem(_ record: DeliveryRecord) -> String? {
        guard record.delivery.meta["opencode_destination_validated"] == "true" else { return nil }
        guard let endpoint = record.delivery.meta["opencode_endpoint"].flatMap(URL.init(string:)),
              let id = record.delivery.meta["opencode_session_id"], let pin = OpenCodeDestination(sessionID: id, endpoint: endpoint) else {
            return ZeusRuntimeCopy.Delivery.openCodeUnknownServer
        }
        guard routing.deliveryMethod == .opencode else {
            return "Switch back to OpenCode delivery in Settings → Assistant to finish sending this, or discard it."
        }
        guard pin.endpoint == routing.openCodeBaseURL.flatMap(OpenCodeDestination.canonicalEndpoint) else {
            return ZeusRuntimeCopy.Delivery.openCodePinnedToOtherServer(Self.serverLabel(pin.endpoint))
        }
        return nil
    }
    static func serverLabel(_ url: URL) -> String {
        (url.host ?? "the original server") + (url.port.map { ":\($0)" } ?? "")
    }
    /// Commit only changed captions. Repeated pane samples must not rewrite history.
    func refreshQueueReasons() {
        do {
            try ledger?.mutateRecords { records in
                for index in records.indices where records[index].isPending && records[index].transportDeliveredAt == nil {
                    let record = records[index]
                    let native = nativeDestinationProblem(record)
                    let managed = managedQueueReason(record)
                    let owned = record.delivery.meta["tmux_paste_destination"] != nil || pendingPasteAhead(of: record) != nil
                    var reason = owned ? "Finishing Zeus's saved message in Terminal." : native ?? managed
                    if owned { records[index].queueReasonSource = .managedGate }
                    else if native != nil { records[index].queueReasonSource = .nativeRoute }
                    else if managed != nil { records[index].queueReasonSource = .managedGate }
                    else if record.queueReasonSource == .nativeRoute {
                        records[index].queueReasonSource = nil
                        reason = "Waiting for OpenCode to confirm this message."
                    } else if record.queueReasonSource == .managedGate {
                        records[index].queueReasonSource = nil
                        reason = "Waiting to send this message."
                    }
                    if let reason, reason != record.queueReason {
                        records[index].queueReason = reason; records[index].stateUpdatedAt = clock.now
                    }
                }
            }
        } catch { storageProblem = "Couldn't save the waiting message's status: \(error.localizedDescription)" }
    }
}
