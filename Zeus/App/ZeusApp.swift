import AppKit
import SwiftUI
import ZeusDesign

@main
struct ZeusApp: App {
    @NSApplicationDelegateAdaptor(ZeusAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { delegate.shell.settings.showMenuBarIcon },
                                          set: { delegate.shell.settings.showMenuBarIcon = $0 })) {
            // MB1: the same menu as Zeus's right-click menu.
            ZeusMenuContent(model: delegate.shell.menuModel) { delegate.shell.perform($0) }
        } label: {
            Image((delegate.shell.cards.hasUnseenCards || delegate.shell.managed.isMenuAlert) ? "MenuBarIconAlert" : "MenuBarIcon")
                .accessibilityLabel(delegate.shell.menuAccessibilityLabel)
        }
    }
}

@MainActor
final class ZeusAppDelegate: NSObject, NSApplicationDelegate {
    lazy var shell: ShellController = {
        #if DEBUG
        if ComposerGrowthProbe.requested { return ComposerGrowthProbe.makeShell() }
        #endif
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        guard !testing else { return ShellController() }
        do { return ShellController(learningServices: try LearningServices.production(), requirePrivateJournal: true) }
        catch { return ShellController(requirePrivateJournal: true) }
    }()
    private(set) var runtime: ZeusRuntime?
    private var messageRatings: MessageRatingStore?


    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit-test hosts must not register global shortcuts, show onboarding, or start a live bridge.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        ZeusFonts.registerBundled()
        #if DEBUG
        if ComposerGrowthProbe.requested {
            guard (try? ComposerGrowthProbe.validatedHome(ProcessInfo.processInfo.environment)) != nil else {
                NSApplication.shared.terminate(nil); return
            }
            shell.start()
            ComposerGrowthProbe.start(shell: shell)
            return
        }
        #endif
        shell.updater.start()
        shell.start()
        #if DEBUG || ZEUS_PERFORMANCE_PROBE
        PerformanceProbe.start(shell: shell)
        #endif
        shell.messaging.retryStartup = { [weak self] in self?.startAgentLink() }
        startAgentLink()
    }

    private func startAgentLink() {
        #if DEBUG
        guard !ComposerGrowthProbe.requested else { return }
        #endif
        guard runtime == nil else { return }
        let settings = shell.settings
        do { messageRatings = try MessageRatingStore(); shell.ratings.startupError = nil }
        catch {
            let message = "Zeus can't open your message preferences right now. Retry the assistant connection to try again."
            shell.ratings.startupError = message; shell.runtimeError = message
            return
        }
        let runtime = ZeusRuntime(cards: shell.cards, status: shell.status,
                                  characters: settings, routing: settings,
                                  quietHours: { [weak settings] date in settings?.isQuiet(at: date) ?? false },
                                  appControl: shell.appControl, learnings: shell.learn.learnings,
                                  rules: shell.learningServices?.rules, journal: shell.learningServices?.journal,
                                  redactor: shell.learningServices?.redactor,
                                  learningFolder: shell.learningServices?.folder as? any LearningFolderRecording,
                                  messageRatings: messageRatings,
                                  learningContext: { [weak learning = shell.learning] in learning?.context ?? .init(isPrivate: true) },
                                  reflectionEnabled: { [weak learning = shell.learning] in learning?.enabled == true },
                                  morningBriefSettings: shell.morningBrief,
                                  morningBriefLevels: { [weak learning = shell.learning] in learning?.journalAccessPolicy.enabledLevels ?? [] })
        shell.connectLearningRuntime(runtime)
        runtime.onOpenAssistantSettings = { [weak shell] in shell?.showSettings(tab: .agent) }
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

    func applicationDidBecomeActive(_ notification: Notification) {
        shell.login.refresh()
        shell.managed.refreshAvailability()
        shell.learning.retryLearningStorage()
    }

    /// MB1: reopening Zeus (Finder, Spotlight, Launchpad, Dock) always brings it back, even with the menu bar icon off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shell.handleReopen()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
        shell.stop()
        #if DEBUG
        if ComposerGrowthProbe.requested { ComposerGrowthProbe.cleanup() }
        #endif
    }
}
