import SwiftUI
import ZeusDesign

/// Maps the shared activity seam onto the designer’s typing indicator.
struct ConversationActivityPresentation: Equatable {
    let phase: AssistantActivity.Phase
    let agentName: String
    let detail: String?
    let progress: Double?

    static func make(_ activity: AssistantActivity?, panelVisible: Bool, sessionLabel: String? = nil,
                     managedStatus: ManagedSessionStatus? = nil, managedSessionKey: String? = nil) -> Self? {
        guard panelVisible, let activity else { return nil }
        if case .blocked = managedStatus, managedSessionKey == nil || activity.sessionKey == managedSessionKey { return nil }
        return .init(phase: activity.phase, agentName: sessionLabel ?? activity.agentName, detail: activity.detail,
                     progress: activity.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
    }
    var typingPhase: ZeusTypingIndicator.Phase {
        switch phase { case .sent: .sent; case .thinking: .thinking; case .working: .working }
    }
    var label: String {
        detail ?? (phase == .sent ? "Sent to \(agentName)…" : phase == .working ? "\(agentName) is working…" : "\(agentName) is thinking…")
    }
}

struct ConversationActivityRow: View {
    let presentation: ConversationActivityPresentation
    var body: some View {
        ZeusTypingIndicator(presentation.typingPhase, agentName: presentation.agentName,
                            detail: presentation.detail, progress: presentation.progress)
    }
}
