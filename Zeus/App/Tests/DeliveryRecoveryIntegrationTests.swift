import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct DeliveryRecoveryIntegrationTests {
    private func fixture() throws -> (String, UserDefaults, AppSettings, TruthManagedController, ManagedAssistantModel) {
        let suite = "zeus-delivery-recovery-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = .init(enabled: true, folder: "/fixture", agent: .claude, launchPrompt: "Fixture", startWhenZeusOpens: false)
        let controller = TruthManagedController()
        controller.deliveryIssue = .init(title: "Waiting", detail: "A fixture message is waiting.", pendingCount: 1, since: .distantPast)
        let model = ManagedAssistantModel(settings: settings, controller: { controller }); model.refreshAvailability()
        return (suite, defaults, settings, controller, model)
    }
    @Test func stoppedPopoverActuallyStartsAndNeverRetriesTheDisconnectedMessage() throws {
        let (suite, defaults, settings, controller, model) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        var closed = 0, opened = 0
        let view = DeliveryWarningView(messaging: controller, settings: settings, managed: model, close: { closed += 1 }, openSettings: { opened += 1 })
        #expect(view.primaryAction?.title == "Start Assistant")
        view.primaryAction?.action()
        #expect(controller.starts == 1 && controller.retries == 0 && closed == 0 && opened == 0)
        controller.managedStatus = .blocked(reason: "Permission")
        #expect(view.primaryAction == nil)
        view.perform(.startAssistant)
        #expect(controller.starts == 1)
    }
    @Test func advancedDisconnectedAndPinnedMessagesCanBeDiscardedWithoutRetry() throws {
        let (suite, defaults, settings, controller, model) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        settings.managedSession?.enabled = false
        var closed = 0
        let view = DeliveryWarningView(messaging: controller, settings: settings, managed: model, close: { closed += 1 }, openSettings: {})
        #expect(view.primaryAction == nil)
        view.perform(.retry); #expect(controller.retries == 0)
        controller.canRetryPendingDeliveries = true
        #expect(view.primaryAction?.title == "Retry Now")
        view.primaryAction?.action(); #expect(controller.retries == 1)
        controller.canRetryPendingDeliveries = false
        view.discard()
        #expect(controller.discards == 1 && controller.deliveryIssue == nil && closed == 1)
    }
    @Test func newConversationRecoveryOpensItsExistingConfirmationInsteadOfStartingBlindly() throws {
        let (suite, defaults, settings, controller, model) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        controller.managedStatus = .failed(reason: "Fixture"); controller.managedNeedsNewConversation = true
        var opened = 0, closed = 0
        let view = DeliveryWarningView(messaging: controller, settings: settings, managed: model, close: { closed += 1 }, openSettings: { opened += 1 })
        #expect(view.primaryAction?.title == "Start New Conversation")
        view.primaryAction?.action()
        #expect(model.confirmation == .newConversation && controller.fresh == 0 && controller.starts == 0)
        #expect(opened == 1 && closed == 1)
        model.confirm(); #expect(controller.fresh == 1)
    }
    @Test func inactiveMenuStatusWinsOverStaleActivityAndDeliveryProblemAndKeepsUnreadCount() throws {
        let (suite, defaults, settings, controller, _) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-menu-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings); cards.onAdd = nil
        shell.messaging.runtime = controller; controller.managedHasLaunched = true
        controller.assistantActivity = .init(phase: .sent, sessionKey: "claude:fixture", agentName: "Claude", detail: nil, progress: nil, since: Date())
        shell.status.setDeliveryProblem("Zeus will keep trying.")
        cards.add(Card(kind: .message, body: "Unread fixture"))
        #expect(shell.menuStatus == "Claude Code is stopped")
        #expect(shell.menuUnreadDetail == "1 unread message")
        #expect(shell.menuAccessibilityLabel.contains("is stopped") && shell.menuAccessibilityLabel.contains("1 unread message"))
        controller.managedHasLaunched = false
        #expect(shell.menuStatus == "Claude Code hasn't started")
    }
}
