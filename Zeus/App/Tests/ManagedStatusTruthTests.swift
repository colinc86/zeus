import Foundation
import Observation
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor @Observable final class TruthManagedController: AgentMessaging, ManagedSessionControlling, ManagedPresentationProviding {
    var sessions: [ConnectedSession] = []
    var managedStatus: ManagedSessionStatus = .stopped
    var managedNeedsNewConversation = false
    var managedHasLaunched = false
    var canRetryPendingDeliveries = false
    var managedTmuxSessionName: String?
    var managedAttachCommand: String?
    var starts = 0
    var fresh = 0
    var retries = 0
    var discards = 0
    var deliveryIssue: DeliveryIssue?
    var assistantActivity: AssistantActivity?
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        [.init(id: "ask", title: "Ask", detail: "Asks first.", isUnrestricted: false, isDefault: true)]
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { nil }
    func startManagedSession() { starts += 1 }
    func stopManagedSession() {}
    func restartManagedSession() { starts += 1 }
    func startNewManagedConversation() { fresh += 1 }
    func openManagedSessionInTerminal() {}
    func sendUserMessage(_ text: String) async -> MessageSendResult { .queued(reason: "Fixture") }
    func retryPendingDeliveries() { retries += 1 }
    func discardPendingDeliveries() { discards += 1; deliveryIssue = nil }
}

@MainActor struct ManagedStatusTruthTests {
    @Test func neverLaunchedAndStoppedPresentDifferentTruthWithoutInventingAnExit() throws {
        let suite = TestDefaults.suite("zeus-status-truth")
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = .init(enabled: true, folder: "/fixture", agent: .claude, launchPrompt: "Fixture", startWhenZeusOpens: false)
        let controller = TruthManagedController(), model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
        #expect(model.isNotStarted && model.presentation().title == "Ready to Start")
        #expect(!model.presentation().detail.contains("exited") && model.presentation().actions == [.start])
        #expect(model.presentation().menuStatus == "Your assistant is off")
        controller.managedHasLaunched = true
        #expect(!model.isNotStarted && model.presentation().title == "Stopped")
        #expect(model.presentation().detail == "Claude Code is stopped. Press Start to run it again.")
        #expect(model.presentation().menuStatus == "Claude Code is stopped")
    }
}
