import AppKit
import SwiftUI
import ZeusDesign

@main
struct ZeusApp: App {
    @NSApplicationDelegateAdaptor(ZeusAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Text(delegate.shell.menuStatus)
            if delegate.shell.managed.enabled {
                ForEach(delegate.shell.managed.menuActions, id: \.self) { action in
                    Button(action.menuTitle) { delegate.shell.performManagedAction(action) }
                        .disabled(delegate.shell.managed.disabledActions.contains(action))
                }
            } else {
                Text(delegate.agentStatusText)
                Menu("Assistant session") {
                    AssistantSessionPicker(settings: delegate.shell.settings, sessions: delegate.shell.messaging.sessions, menuChrome: false)
                        .pickerStyle(.inline)
                }
                if let notice = delegate.shell.settings.assistantSessionNotice { Text(notice) }
            }
            if let detail = delegate.shell.menuUnreadDetail { Text(detail) }
            if let issue = delegate.shell.menuIssueDetail { Text(issue) }
            if let until = delegate.shell.visibility.hiddenUntil {
                Text("Hidden until \(until.formatted(date: .abbreviated, time: .shortened))")
            }
            Divider()
            Button(delegate.shell.isVisible ? "Hide Zeus" : "Show Zeus") {
                delegate.shell.toggleVisibility()
            }
            Button(MenuPresentation.hideForHour) { delegate.shell.hide(for: .hour) }
            Button(MenuPresentation.hideUntilTomorrow) { delegate.shell.hide(for: .tomorrow) }
            if delegate.shell.messaging.deliveryIssue != nil {
                Button("Delivery problem…") { delegate.shell.showDeliveryProblem() }
            }
            Button("Talk to Zeus…") { delegate.shell.showTalkPanel() }
                .keyboardShortcut(delegate.shell.settings.talkHotKey.menuShortcut)
            Button("Settings…") { delegate.shell.showSettings() }
                .keyboardShortcut(",")
            Button(delegate.shell.updater.menuTitle) { delegate.shell.updater.checkForUpdates() }
                .disabled(!delegate.shell.updater.canCheckForUpdates)
                .help(delegate.shell.updater.unavailableReason ?? "Check for a new version of Zeus")
            if let reason = delegate.shell.updater.unavailableReason { Text(reason) }
            Button("About Zeus") { delegate.shell.showSettings(tab: .about) }
            Divider()
            Button("Quit Zeus") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image((delegate.shell.cards.hasUnseenCards || delegate.shell.managed.isMenuAlert) ? "MenuBarIconAlert" : "MenuBarIcon")
                .accessibilityLabel(delegate.shell.menuAccessibilityLabel)
        }
    }
}

@MainActor
final class ZeusAppDelegate: NSObject, NSApplicationDelegate {
    let shell = ShellController()
    private(set) var runtime: ZeusRuntime?

    var agentStatusText: String {
        if shell.messaging.previewEnabled { return "Preview messaging" }
        guard runtime != nil else { return "Not connected to your assistant" }
        switch shell.messaging.sessions.count {
        case 0: return "No assistant connected"
        case 1: return "1 assistant session connected"
        case let n: return "\(n) assistant sessions connected"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit-test hosts must not register global shortcuts, show onboarding, or start a live bridge.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        ZeusFonts.registerBundled()
        shell.updater.start()
        shell.start()
        #if DEBUG || ZEUS_PERFORMANCE_PROBE
        PerformanceProbe.start(shell: shell)
        #endif
        #if DEBUG
        ComposerGrowthProbe.start(shell: shell)
        #endif
        shell.messaging.retryStartup = { [weak self] in self?.startAgentLink() }
        startAgentLink()
    }

    private func startAgentLink() {
        guard runtime == nil else { return }
        let settings = shell.settings
        let runtime = ZeusRuntime(cards: shell.cards, status: shell.status,
                                  characters: settings, routing: settings,
                                  quietHours: { [weak settings] date in settings?.isQuiet(at: date) ?? false },
                                  appControl: shell.appControl, learnings: shell.learn.learnings)
        do {
            try runtime.start()
            self.runtime = runtime
            shell.messaging.runtime = runtime
            shell.managed.createFolder = { [weak runtime] in
                guard let runtime else { throw CancellationError() }
                return try runtime.createDefaultFolder()
            }
            shell.managed.refreshAvailability()
            shell.runtimeError = nil
            shell.messaging.pendingHistoryIDs = { [weak runtime] in
                guard let runtime else { return [] }
                let pending = (runtime.ledger?.records ?? []).filter { $0.delivery.ackedAt == nil }.compactMap { $0.delivery.cardID }
                return Set(pending + runtime.unsaved.compactMap { $0.delivery.cardID } + (runtime.responseJournal?.intents.map(\.cardID) ?? []))
            }
            shell.cards.pendingHistoryIDs = { [weak shell] in shell?.messaging.pendingHistoryIDs?() ?? [] }
        } catch {
            runtime.stop()
            shell.runtimeError = error.localizedDescription
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { shell.login.refresh() }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
        shell.stop()
    }
}
