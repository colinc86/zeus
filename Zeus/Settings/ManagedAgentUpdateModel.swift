import Foundation
import Observation

/// App-owned quiet notices. The controller owns detection and every safety check at restart time.
@MainActor final class ManagedAgentUpdateModel {
    private let managed: ManagedAssistantModel
    private let cards: CardStore
    private let clock: () -> Date
    var onConfirmation: (() -> Void)?
    private var conversationID: String?
    private var wasPending = false
    private var noticeID: String?
    private var awaitingRestart = false
    private var confirmationWasOpen = false
    private var restartIDAtRequest: UUID?
    private var noticeSummary: String?

    init(managed: ManagedAssistantModel, cards: CardStore, clock: @escaping () -> Date = Date.init) {
        self.managed = managed; self.cards = cards; self.clock = clock
        reconcile(); observe()
    }

    /// Also callable by deterministic fixtures; normal operation is driven by observation, never a polling timer.
    func reconcile() {
        let conversation = managed.agentUpdater?.managedAgentUpdateConversationID
        let pending = managed.agentUpdatePending
        if conversation != conversationID {
            if conversation != nil { deactivateNotice() }
            else if let noticeID { cards.setNoticeAction(id: noticeID, action: nil) }
            conversationID = conversation; noticeID = nil; wasPending = false; awaitingRestart = false
            noticeSummary = "\(managed.agentName) has an update"
        }
        guard let conversation else { return }
        if pending && !wasPending {
            // Re-adopting the same conversation after a Zeus relaunch reuses its active notice.
            let saved = managed.settings.managedAgentUpdateNoticeState
            noticeID = saved?.conversationID == conversation && saved?.pending == true ? saved?.noticeID : nil
            if noticeID == nil {
                noticeID = cards.notices.last {
                    $0.kind == .agentUpdate && $0.id.hasPrefix("agent-update:\(conversation):") && $0.isAgentUpdateCurrent == true
                }?.id
            }
        }
        // Quitting/detaching Zeus is not a sampled update-clear edge in the agent it leaves running.
        if !pending && wasPending && !managed.agentUpdateRestartPending && managed.status != .off { deactivateNotice() }
        wasPending = pending
        if managed.agentUpdateRestartPending {
            if !awaitingRestart { restartIDAtRequest = managed.agentUpdateRestartID }
            awaitingRestart = true; confirmationWasOpen = false
            updateCurrent(summary: managed.agentUpdateWaitingText, resolved: nil, actionable: false)
            return
        }
        if awaitingRestart {
            awaitingRestart = false
            if let error = managed.agentUpdateRestartError {
                var detail = error.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !detail.hasSuffix(".") && !detail.hasSuffix("!") && !detail.hasSuffix("?") { detail += "." }
                updateCurrent(summary: "Couldn't restart \(managed.agentName). \(detail)", resolved: nil, actionable: pending)
                return
            } else if !pending {
                deactivateNotice(restarted: managed.agentUpdateRestartID != nil && managed.agentUpdateRestartID != restartIDAtRequest); return
            }
        }
        let confirming: Bool
        if case .restartForUpdate = managed.confirmation { confirming = true } else { confirming = false }
        if confirmationWasOpen && !confirming && pending {
            updateCurrent(summary: "\(managed.agentName) has an update", resolved: "Later", actionable: false)
        }
        confirmationWasOpen = confirming
        guard pending, managed.hasActiveSession, !cards.hasOpenQuestion, !isBlocked else {
            if let noticeID { cards.setNoticeAction(id: noticeID, action: nil) }
            return
        }
        if noticeID == nil {
            let notice = ThreadNotice(id: "agent-update:\(conversation):\(UUID().uuidString)", kind: .agentUpdate,
                createdAt: clock(), summary: "\(managed.agentName) has an update", actionTitle: "Restart assistant", isAgentUpdateCurrent: true)
            if cards.recordNotice(notice) {
                noticeID = notice.id
                managed.settings.managedAgentUpdateNoticeState = .init(conversationID: conversation, noticeID: notice.id, pending: true)
            }
        }
        guard let noticeID, let notice = cards.notices.first(where: { $0.id == noticeID }), notice.resolvedTitle != "Later" else { return }
        if confirming {
            updateCurrent(summary: "\(managed.agentName) has an update", resolved: nil, actionable: false)
        } else {
            updateCurrent(summary: "\(managed.agentName) has an update", resolved: nil, actionable: managed.agentUpdateCanRestart)
        }
    }

    private var isBlocked: Bool { if case .blocked = managed.status { true } else { false } }
    private func updateCurrent(summary: String, resolved: String?, actionable: Bool, active: Bool? = nil) {
        guard let noticeID, let old = cards.notices.first(where: { $0.id == noticeID }) else { return }
        var next = old; if let active { next.isAgentUpdateCurrent = active }; next.summary = summary; next.resolvedTitle = resolved
        next.actionTitle = actionable ? "Restart assistant" : nil
        guard next == old || cards.updateNotice(id: noticeID, { $0 = next }) else { return }
        if actionable { cards.setNoticeAction(id: noticeID, action: { [weak self] in self?.restart() }) }
        else { cards.setNoticeAction(id: noticeID, action: nil) }
    }
    private func deactivateNotice(restarted: Bool = false) {
        if let conversationID, let noticeID {
            managed.settings.managedAgentUpdateNoticeState = .init(conversationID: conversationID, noticeID: noticeID, pending: false)
        }
        guard let noticeID, let notice = cards.notices.first(where: { $0.id == noticeID }) else { return }
        updateCurrent(summary: noticeSummary ?? notice.summary, resolved: restarted ? "Restarted" : nil, actionable: false, active: false)
    }
    private func restart() {
        guard !cards.hasOpenQuestion, !isBlocked else { reconcile(); return }
        managed.requestAgentUpdateRestart()
        if case .restartForUpdate = managed.confirmation { confirmationWasOpen = true; onConfirmation?() }
        reconcile()
    }
    private func observe() {
        withObservationTracking {
            _ = managed.agentUpdatePending; _ = managed.agentUpdater?.managedAgentUpdateConversationID
            _ = managed.agentUpdateRestartPending; _ = managed.agentUpdateRestartError; _ = managed.agentUpdateRestartID
            _ = managed.agentUpdateCanRestart; _ = managed.status; _ = managed.confirmation
            _ = cards.hasOpenQuestion; _ = cards.threadRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconcile(); self?.observe()
            }
        }
    }
}
