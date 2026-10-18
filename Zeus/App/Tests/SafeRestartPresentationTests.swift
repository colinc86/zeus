import AppKit
import SwiftUI
import ZeusDesign
import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private struct RestartCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}

@MainActor @Observable private final class RestartPresentationController: AgentMessaging, ManagedSessionControlling, ManagedSettingsApplying, ManagedRestartRecovering {
    var sessions: [ConnectedSession] = []
    var managedStatus: ManagedSessionStatus = .running(.working)
    var managedTmuxSessionName: String? = "fixture"
    var managedAttachCommand: String? = "fixture"
    var managedAppliedConfiguration: ManagedSessionConfig?
    var managedSettingsApplication: ManagedSettingsApplication?
    var managedSettingsApplicationError: String?
    var managedCanResumeSettings = true
    var managedRestartNowToken: String?
    var forced: [String] = []
    func restartManagedSessionNow(token: String) { forced.append(token) }
    func supportsInstructionChangesOnResume(for agent: AgentKind) -> Bool { true }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] { [.init(id: "ask", title: "Ask", detail: "Ask", isUnrestricted: false, isDefault: true)] }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { nil }
    func startManagedSession() {}
    func stopManagedSession() {}
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
    func applyManagedSettings(_ configuration: ManagedSessionConfig) {}
    func switchManagedSettings(_ configuration: ManagedSessionConfig) {}
    func cancelManagedSettingsApplication() { managedSettingsApplication = nil }
    func restartManagedSession() {
        if let config = managedAppliedConfiguration { managedSettingsApplication = .init(id: UUID(), configuration: config, kind: .restart) }
    }
    func sendUserMessage(_ text: String) async -> MessageSendResult { .queued(reason: "Fixture") }
}

@MainActor struct SafeRestartPresentationTests {
    private func withShell(_ body: (ShellController, RestartPresentationController) throws -> Void) throws {
        let name = "zeus-fx17-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: RestartCredentials())
        var config = AppSettings.newManagedSession(); config.folder = root.path
        settings.managedSession = config; settings.managedLaunchedConfig = config; settings.managedAgentInitialized = true
        let controller = RestartPresentationController(); controller.managedAppliedConfiguration = config
        let shell = ShellController(defaults: defaults, cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), settings: settings)
        shell.messaging.runtime = controller; shell.managed.refreshAvailability()
        try body(shell, controller)
    }

    @Test func ordinaryRestartShowsWaitingAndCanBeCancelledWithoutRecovery() throws {
        try withShell { shell, controller in
            shell.performManagedAction(.restart)
            #expect(shell.managed.ordinaryRestartPending && shell.managed.canCancelRestart)
            #expect(shell.menuStatus == "Restarting when Claude Code is idle…")
            #expect(shell.managed.note == shell.managed.agentUpdateWaitingText)
            #expect(!shell.managed.menuActions.contains(.restartNow))
            shell.perform(.cancelManagedRestart)
            #expect(controller.managedSettingsApplication == nil && controller.forced.isEmpty)
        }
    }

    @Test func recoveryRequiresConfirmationAndRevalidatesTheExactToken() throws {
        try withShell { shell, controller in
            shell.performManagedAction(.restartNow)
            #expect(shell.managed.confirmation == nil)
            controller.managedRestartNowToken = "old-pane"
            var presented = 0
            shell.performManagedAction(.restartNow, onConfirmation: { presented += 1 })
            #expect(presented == 1 && shell.managed.confirmation == .restartNow && controller.forced.isEmpty)
            controller.managedRestartNowToken = "new-pane"
            shell.managed.confirm()
            #expect(controller.forced.isEmpty)
            shell.performManagedAction(.restartNow, onConfirmation: { presented += 1 })
            shell.managed.confirm()
            #expect(controller.forced == ["new-pane"])
        }
    }

    @Test func deadRecoveryHasOnePrimaryActionAndNamesTheAgent() throws {
        try withShell { shell, controller in
            controller.managedStatus = .failed(reason: "Process exited")
            controller.managedRestartNowToken = "dead-pane"
            let presentation = shell.managed.presentation()
            #expect(presentation.actions.first == .restartNow)
            #expect(!presentation.actions.contains(.start) && !presentation.actions.contains(.tryAgain))
            #expect(!shell.managed.menuActions.contains(.start))
            #expect(presentation.detail == "Claude Code exited.")
        }
    }

    @Test func menuSwitchAndEveryConfirmationHaveAVisibleSettingsTarget() throws {
        try withShell { shell, _ in
            shell.managed.chooseAgent(.codex); shell.managed.cancelConfirmation()
            var presented = 0
            shell.performManagedAction(.restart, onConfirmation: { presented += 1 })
            #expect(presented == 1 && shell.managed.confirmation == .switchConversation)
            let mode = ManagedPermissionMode(id: "full", title: "Unrestricted", detail: "Full", isUnrestricted: true, isDefault: false)
            let cases: [ManagedAssistantModel.Confirmation] = [.switchToOwn, .unrestricted(mode), .newConversation, .switchConversation, .restartForUpdate(mode), .restartForSetup(mode), .restartNow]
            for confirmation in cases {
                shell.managed.confirmation = confirmation
                #expect(SettingsView.managedConfirmationTarget(confirmation) != nil)
                let before = presented
                shell.performManagedAction(.openInTerminal, onConfirmation: { presented += 1 })
                #expect(presented == before + 1)
            }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FX17_RENDER"] == "1" || ProcessInfo.processInfo.environment["TEST_RUNNER_FX17_RENDER"] == "1"))
    func restartSettingsRenders() async throws {
        ZeusFonts.registerBundled()
        let name = "zeus-fx17-render-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: RestartCredentials())
        var config = AppSettings.newManagedSession(); config.folder = "/Synthetic Assistant"
        settings.managedSession = config; settings.managedLaunchedConfig = config; settings.managedAgentInitialized = true
        let controller = RestartPresentationController(); controller.managedAppliedConfiguration = config
        let managed = ManagedAssistantModel(settings: settings, controller: { controller })
        let messaging = AgentMessagingHub(); messaging.runtime = controller
        managed.refreshAvailability()
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let output = repo.appendingPathComponent("build/tmp/fx17/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for state in ["waiting", "blocked", "dead"] {
            controller.managedSettingsApplication = state == "waiting" ? .init(id: UUID(), configuration: config, kind: .restart) : nil
            controller.managedStatus = state == "waiting" ? .running(.working) : state == "blocked" ? .blocked(reason: "Permission required") : .failed(reason: "Claude Code exited.")
            controller.managedRestartNowToken = state == "waiting" ? nil : "fixture"
            managed.confirmation = state == "waiting" ? nil : .restartNow
            for scheme in [ColorScheme.light, .dark] {
                let host = TestHostingView(rootView: ScrollView {
                    AssistantSettingsView(settings: settings, managed: managed, messaging: messaging, testMessage: ComposeModel(cards: CardStore(fileURL: output.appendingPathComponent("fixture-cards.json")), messaging: messaging)).padding(24)
                }.frame(width: 792, height: 760).environment(\.colorScheme, scheme).environment(\.zeusFontChoice, .system).background(ZeusPalette.for(scheme).panel))
                let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 792, height: 760), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
                for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("fx17-\(state)-\(scheme).png"))
                window.contentView = nil; window.close()
            }
        }
    }

}
