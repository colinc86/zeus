import Foundation
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor struct ManagedFreshRecoveryTests {
    @Test(arguments: [ManagedSessionStatus.stopped, .failed(reason: "Raw missing ID"), .restarting(at: .distantFuture)])
    func missingConversationOffersFreshRecoveryAndNeverPromisesAResume(state: ManagedSessionStatus) throws {
        let suite = TestDefaults.suite("zeus-fresh-recovery")
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = .init(enabled: true, folder: "/fixture", agent: .codex, launchPrompt: "Fixture", startWhenZeusOpens: false)
        settings.managedLaunchedConfig = settings.managedSession
        let controller = TruthManagedController(); controller.managedStatus = state; controller.managedNeedsNewConversation = true
        controller.managedHasLaunched = true; controller.managedTmuxSessionName = "zeus"
        controller.managedAttachCommand = "tmux attach -t =zeus"
        let model = ManagedAssistantModel(settings: settings, controller: { controller }); model.refreshAvailability()
        let presentation = model.presentation()
        #expect(presentation.title == ZeusRuntimeCopy.Managed.cantResumeTitle)
        #expect(presentation.detail == ZeusRuntimeCopy.Managed.cantResume(agent: "Codex"))
        #expect(!presentation.detail.contains("resume the same") && !presentation.title.contains("Restarting"))
        #expect(presentation.actions == [.newConversation, .openInTerminal])
        #expect(model.menuActions == [.newConversation, .openInTerminal])
        #expect(!model.disabledActions.contains(.newConversation))
        model.perform(.start) // A stale menu's Start goes to the same confirmation.
        #expect(model.confirmation == .newConversation && controller.starts == 0 && controller.fresh == 0)
        model.cancelConfirmation(); model.perform(.restart)
        #expect(model.confirmation == .newConversation && controller.starts == 0)
        model.cancelConfirmation(); model.perform(.newConversation); model.confirm()
        #expect(controller.fresh == 1 && controller.starts == 0)
        model.update { $0.folder = "" }
        #expect(model.disabledActions.contains(.newConversation))
        model.perform(.newConversation)
        #expect(model.confirmation == nil && controller.fresh == 1)
    }

    @Test func menuRecoveryPresentsTheConfirmationAndWaitsForItsApproval() throws {
        let suite = TestDefaults.suite("zeus-menu-fresh-recovery")
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-menu-fresh-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = .init(enabled: true, folder: "/fixture", agent: .codex, launchPrompt: "Fixture", startWhenZeusOpens: false)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings); cards.onAdd = nil
        let controller = TruthManagedController(); controller.managedStatus = .failed(reason: "Missing ID"); controller.managedNeedsNewConversation = true
        shell.messaging.runtime = controller; shell.managed.refreshAvailability()
        var confirmations = 0
        shell.performManagedAction(.newConversation, onConfirmation: { confirmations += 1 })
        #expect(confirmations == 1 && shell.managed.confirmation == .newConversation && controller.fresh == 0)
        shell.managed.cancelConfirmation()
        #expect(controller.fresh == 0)
        shell.performManagedAction(.start, onConfirmation: { confirmations += 1 })
        #expect(confirmations == 2 && controller.starts == 0)
        shell.managed.confirm()
        #expect(controller.fresh == 1)
    }
}
