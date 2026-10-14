#if DEBUG || ZEUS_PERFORMANCE_PROBE
import Foundation

/// Opt-in measurement controls for an isolated perf.sh launch; absent in ordinary Release builds.
/// No input automation or access to the human's running app is involved.
@MainActor
enum PerformanceProbe {
    static func start(shell: ShellController) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ZEUS_PERF_DIAGNOSTICS"] == "1" else { return }
        // perf.sh uses an isolated home. Refuse these controls in an ordinary app launch.
        guard environment["CFFIXED_USER_HOME"] != nil else { return }
        if environment["ZEUS_PERF_IGNORE_OCCLUSION"] == "1" { shell.enableUnoccludedPerformanceProbe() }
        if let rawPhase = environment["ZEUS_PERF_ACTIVITY"], let phase = AgentMessagingHub.PreviewActivity(rawValue: rawPhase), phase != .none {
            shell.messaging.previewEnabled = true
            shell.messaging.previewActivity = phase
            shell.messaging.previewActivityProgress = phase == .working ? 0.4 : nil
        }
        if environment["ZEUS_PERF_LONG_MESSAGE"] == "1", let card = shell.cards.cards.last {
            shell.cards.update(id: card.id) { $0.body = DemoCardKind.longMessageBody }
        }
        if environment["ZEUS_PERF_PANEL"] == "conversation" {
            shell.preparePassivePerformancePanel()
            shell.showTalkPanel()
        }
        if environment["ZEUS_PERF_SCROLL"] == "1" { ScrollBenchmark.start(shell: shell) }
        Task { @MainActor [weak shell] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let shell else { return }
            let activity = shell.surfaceActivity
            let scroll = shell.cardPanelState.viewportForDiagnostics
            let line = "ZEUS_PERF: avatarActive=\(activity.avatar) conversationActive=\(activity.conversation) peekActive=\(activity.peek) settingsActive=\(activity.settings) conversationMounted=\(shell.isConversationMounted) deadlineScheduled=\(shell.scheduledDeadline != nil) assistantActivity=\(shell.messaging.assistantActivity.map { String(describing: $0.phase) } ?? "none") activityRowVisible=\(shell.cardPanelState.activityRowVisibleForDiagnostics) scrollOffset=\(scroll.offset) scrollContent=\(scroll.contentHeight) scrollHeight=\(scroll.height) newestMessageTop=\(shell.cardPanelState.newestMessageTopForDiagnostics.map { String(describing: $0) } ?? "none") \(shell.performanceVisibility)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}
#endif
