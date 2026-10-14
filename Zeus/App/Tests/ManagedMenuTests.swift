import Foundation
import Observation
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor @Observable private final class MenuManagedMessaging: AgentMessaging, ManagedSessionControlling {
    var sessions: [ConnectedSession] = []
    var managedStatus: ManagedSessionStatus = .blocked(reason: "Permission")
    var managedTmuxSessionName: String? { nil }
    var managedAttachCommand: String? { nil }
    var installed = false
    var starts = 0
    var restarts = 0
    func sendUserMessage(_ text: String) async -> MessageSendResult { .queued(reason: "Waiting") }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        installed ? [.init(id: "ask", title: "Ask", detail: "Asks first.", isUnrestricted: false, isDefault: true)] : []
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { nil }
    func startManagedSession() { starts += 1 }
    func stopManagedSession() {}
    func restartManagedSession() { restarts += 1 }
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
}

@MainActor struct ManagedMenuTests {
    @Test func menuRetryAndRestartNowShareTheManagedActionAvailabilityGuards() throws {
        let suite = "zeus-menu-actions-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = .init(enabled: true, folder: "/fixture", agent: .claude,
            permissionModeID: "ask", launchPrompt: "Fixture", startWhenZeusOpens: false)
        let controller = MenuManagedMessaging()
        let model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
        for action in [ZeusManagedPresentation.Action.start, .tryAgain, .restart, .restartNow] {
            #expect(model.disabledActions.contains(action))
            model.perform(action)
        }
        #expect(controller.starts == 0 && controller.restarts == 0)
        controller.managedStatus = .failed(reason: "Crash")
        #expect(model.menuActions.contains(.start) && model.disabledActions.contains(.start))
        controller.installed = true; model.refreshAvailability()
        for action in [ZeusManagedPresentation.Action.start, .tryAgain, .restart, .restartNow] {
            #expect(!model.disabledActions.contains(action))
        }
        model.perform(.tryAgain); model.perform(.restartNow)
        #expect(controller.starts == 1 && controller.restarts == 1)
        controller.managedStatus = .running(.idle)
        model.chooseManaged(false); model.confirm()
        #expect(model.switching)
        #expect(model.disabledActions.contains(.tryAgain) && model.disabledActions.contains(.restartNow))
        model.perform(.tryAgain); model.perform(.restartNow)
        #expect(controller.starts == 1 && controller.restarts == 1)
    }

    @Test func managedAlertsKeepTheirStatusAlongsideUnreadAndOrdinaryUnreadHasOneLine() throws {
        let suite = "zeus-menu-alert-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-menu-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedLaunchedConfig = settings.managedSession
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings)
        cards.onAdd = nil // No native panels, announcements, or global shortcuts in this test.
        let controller = MenuManagedMessaging(); shell.messaging.runtime = controller
        cards.add(Card(kind: .message, body: "Unread block explanation"))
        #expect(shell.menuStatus == "Claude Code is waiting for you in Terminal")
        #expect(shell.menuUnreadDetail == "1 unread message")
        #expect(shell.menuAccessibilityLabel.contains("waiting for you in Terminal") && shell.menuAccessibilityLabel.contains("1 unread message"))
        cards.markAllSeen()
        #expect(shell.menuStatus == "Claude Code is waiting for you in Terminal" && shell.menuUnreadDetail == nil)
        cards.add(Card(kind: .message, body: "Another unread message"))
        controller.managedStatus = .failed(reason: "Repeated quits")
        #expect(shell.menuStatus.contains("Claude Code") && shell.menuStatus != "1 new message")
        #expect(shell.menuUnreadDetail == "1 unread message" && shell.managed.menuActions == [.start])
        #expect(shell.managed.disabledActions.contains(.tryAgain))
        controller.managedStatus = .running(.idle)
        #expect(shell.menuStatus.contains("Claude Code is ready") && shell.menuUnreadDetail == "1 unread message")
        #expect(shell.menuAccessibilityLabel.contains("Claude Code is ready") && shell.menuAccessibilityLabel.contains("1 unread message"))
        settings.managedSession?.enabled = false
        #expect(shell.menuStatus == "1 new message" && shell.menuUnreadDetail == nil)
        #expect(shell.menuAccessibilityLabel == "Zeus · 1 unread message")
    }
}
