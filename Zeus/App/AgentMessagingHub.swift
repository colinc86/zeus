import Foundation
import Observation
import ZeusProtocol

/// App-local composition adapter. UI consumers see only AgentMessaging; previews are explicitly opt-in.
@MainActor
@Observable
final class AgentMessagingHub: AgentMessaging {
    var startupError: String?
    @ObservationIgnored var retryStartup: (() -> Void)?
    @ObservationIgnored var pendingHistoryIDs: (() -> Set<String>)?
    var startupRecoveryHint: String {
        let reason = startupError?.lowercased() ?? ""
        if reason.contains("in use") || reason.contains("already running") || reason.contains("occupied") {
            return "Close the other copy of Zeus, then try again."
        }
        if ["data", "read", "format", "ledger", "permission", "access"].contains(where: reason.contains) {
            return "Your saved files are safe. Check that Zeus can read its data folder, or restore a backup there, then try again."
        }
        return "Your saved files are safe. Check the reason above, then try again."
    }
    func retryAgentLink() { retryStartup?() }
    var runtime: (any AgentMessaging)?
    var previewEnabled = false
    var previewDeliveryIssue: DeliveryIssue?
    var previewOutcome = PreviewOutcome.delivered
    var previewActivity = PreviewActivity.none {
        didSet { if oldValue != previewActivity { previewActivitySince = Date() } }
    }
    var previewActivityDetail = "Drafting a response"
    var previewActivityProgress: Double? = nil
    private var previewActivitySince = Date()

    enum PreviewActivity: String, CaseIterable, Identifiable {
        case none, sent, thinking, working
        var id: String { rawValue }
        var phase: AssistantActivity.Phase? {
            switch self { case .none: nil; case .sent: .sent; case .thinking: .thinking; case .working: .working }
        }
    }
    private(set) var previewMessages: [String] = []

    enum PreviewOutcome: String, CaseIterable, Identifiable {
        case delivered, queued, failed
        var id: String { rawValue }
        var result: MessageSendResult {
            switch self {
            case .delivered: .delivered
            case .queued: .queued(reason: "Preview assistant is disconnected. Saved for later.")
            case .failed: .failed(reason: "Preview assistant has no delivery target.")
            }
        }
    }

    var sessions: [ConnectedSession] {
        if previewEnabled { return Self.previewSessions }
        return runtime?.sessions ?? []
    }

    private var previewDeliveries: [String: UserMessageDelivery] = [:]
    var userMessageDeliveries: [UserMessageDelivery] {
        previewEnabled ? Array(previewDeliveries.values).sorted { $0.createdAt > $1.createdAt } : runtime?.userMessageDeliveries ?? []
    }
    func sendUserMessage(_ text: String) async -> MessageSendResult {
        await sendUserMessage(text, deliveryID: UserMessageDelivery.makeID())
    }
    func sendUserMessage(_ text: String, deliveryID: String) async -> MessageSendResult {
        if previewEnabled {
            if let existing = previewDeliveries[deliveryID] {
                guard existing.text == text else { return .failed(reason: "This message ID already belongs to different text.") }
                return existing.state == .queued ? .queued(reason: existing.reason ?? "Waiting for preview assistant.") : .delivered
            }
            previewMessages.append(text)
            let outcome = previewOutcome.result
            if case .failed = outcome { return outcome }
            let now = Date()
            previewDeliveries[deliveryID] = .init(id: deliveryID, text: text, sessionKey: Self.previewSessions[0].sessionKey,
                state: previewOutcome == .queued ? .queued : .delivered,
                reason: previewOutcome == .queued ? "Preview assistant is disconnected. Saved for later." : nil,
                createdAt: now, updatedAt: now, recovered: false)
            if previewOutcome == .delivered { previewActivitySince = now; previewActivity = .sent }
            return outcome
        }
        guard let runtime else { return .failed(reason: "Zeus isn't connected to your assistant. Retry, or check Settings → Assistant.") }
        return await runtime.sendUserMessage(text, deliveryID: deliveryID)
    }

    var deliveryIssue: DeliveryIssue? { previewEnabled ? previewDeliveryIssue : runtime?.deliveryIssue }
    var assistantActivity: AssistantActivity? {
        guard previewEnabled else { return runtime?.assistantActivity }
        guard let phase = previewActivity.phase else { return nil }
        return AssistantActivity(phase: phase, sessionKey: Self.previewSessions[0].sessionKey, agentName: "Preview Claude",
                                 detail: phase == .working ? previewActivityDetail : nil,
                                 progress: phase == .working ? previewActivityProgress : nil, since: previewActivitySince)
    }
    func retryPendingDeliveries() {
        if previewEnabled {
            if previewOutcome == .delivered {
                previewDeliveryIssue = nil
                updatePreviewDeliveries(to: .delivered)
            }
            return
        }
        runtime?.retryPendingDeliveries()
    }
    func discardPendingDeliveries() {
        if previewEnabled { previewDeliveryIssue = nil; previewActivity = .none; updatePreviewDeliveries(to: .discarded); return }
        runtime?.discardPendingDeliveries()
    }

    private func updatePreviewDeliveries(to state: UserMessageDelivery.State) {
        previewDeliveries = previewDeliveries.mapValues { record in
            guard record.state == .queued || record.state == .delivered else { return record }
            return .init(id: record.id, text: record.text, sessionKey: record.sessionKey, state: state, reason: nil,
                         createdAt: record.createdAt, updatedAt: Date(), recovered: false)
        }
    }

    private static let previewSessions = [
        ConnectedSession(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
                         sessionKey: "claude:/preview/Zeus", agent: .claude, cwd: "/preview/Zeus", clientName: "Preview Claude",
                         supportsChannel: true, tmuxPane: nil, connectedAt: Date()),
        ConnectedSession(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
                         sessionKey: "codex:/preview/Zeus#%3", agent: .codex, cwd: "/preview/Zeus", clientName: "Preview Codex",
                         supportsChannel: false, tmuxPane: "%3", connectedAt: Date().addingTimeInterval(-60))
    ]
}
