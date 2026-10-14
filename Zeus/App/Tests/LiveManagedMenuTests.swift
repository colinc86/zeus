import Foundation
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor struct LiveManagedMenuTests {
    @Test(arguments: [ManagedSessionStatus.off, .starting, .running(.idle), .running(.working), .running(.unknown),
                      .blocked(reason: "Trust?"), .stopped, .restarting(at: .distantFuture), .failed(reason: "Fixture")])
    func everyManagedStateKeepsItsOwnStatusAndUnreadCount(state: ManagedSessionStatus) throws {
        let suite = "zeus-live-menu-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-live-menu-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = .init(enabled: true, folder: "/Managed", agent: .claude, launchPrompt: "Fixture", startWhenZeusOpens: false)
        settings.managedLaunchedConfig = settings.managedSession
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings); cards.onAdd = nil
        let controller = TruthManagedController(); controller.managedStatus = state; controller.managedHasLaunched = true
        controller.assistantActivity = .init(phase: .thinking, sessionKey: "claude:/AgentHome#900.1", agentName: "Other Claude",
                                             detail: "AgentHome is thinking", progress: nil, since: Date())
        shell.messaging.runtime = controller
        let expected = shell.managed.presentation()
        #expect(shell.menuStatus == (expected.menuStatus ?? expected.detail))
        #expect(!shell.menuStatus.contains("AgentHome"))
        shell.runtimeError = "Fixture connection failed"
        #expect(shell.menuIssueDetail == "Fixture connection failed" && shell.menuStatus == (expected.menuStatus ?? expected.detail))
        shell.runtimeError = nil
        for index in 0..<3 { cards.add(Card(kind: .message, body: "Unread \(index)")) }
        #expect(shell.menuStatus == (expected.menuStatus ?? expected.detail))
        #expect(shell.menuUnreadDetail == "3 unread messages")
        #expect(shell.menuAccessibilityLabel.contains(shell.menuStatus) && shell.menuAccessibilityLabel.contains("3 unread messages"))
        cards.markAllSeen()
        #expect(shell.menuUnreadDetail == nil && shell.menuStatus == (expected.menuStatus ?? expected.detail))
        settings.managedSession?.enabled = false
        #expect(shell.menuStatus.contains("AgentHome"))
    }
}
