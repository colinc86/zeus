import Foundation
import Observation
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

/// A controller stand-in: no tmux, no agent configs, no processes.
@MainActor @Observable
private final class R4cController: ManagedSessionControlling {
    var managedStatus: ManagedSessionStatus = .off
    var managedTmuxSessionName: String?
    var managedAttachCommand: String?
    var installed: Set<AgentKind> = [.claude]
    var problems: [AgentKind: String] = [:]
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        installed.contains(agent) ? [.init(id: "ask", title: "Ask", detail: "Asks first.", isUnrestricted: false, isDefault: true)] : []
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { problems[agent] }
    func startManagedSession() {}
    func stopManagedSession() {}
    func restartManagedSession() {}
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
}

/// R4c: copy and small presentation rules from the Round 3 designer audit.
@MainActor struct R4cCopyTests {
    private static func model(controller: R4cController?) throws -> (ManagedAssistantModel, () -> Void) {
        let suite = "zeus-r4c-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    /// D3-8: without a runtime, the rows don't each repeat the problem, Check Again is hidden (it can't do
    /// anything), and the note stands on its own.
    @Test func noControllerSaysItOnceWithoutAnInertButton() throws {
        let (model, cleanup) = try Self.model(controller: nil); defer { cleanup() }
        #expect(ManagedAssistantModel.agents.allSatisfy { model.agentDetail($0) == nil })
        #expect(!model.showsCheckAgain)
        #expect(model.note == ManagedAssistantModel.noControllerNote)
        #expect(!ManagedAssistantModel.noControllerNote.contains("above"))
    }

    /// D3-8: with a controller, a missing agent explains itself and Check Again shows; installed agents have no detail.
    @Test func missingAgentsExplainThemselves() throws {
        let controller = R4cController()
        controller.problems = [.codex: "Not installed. Install Codex, then press Check Again."]
        let (model, cleanup) = try Self.model(controller: controller); defer { cleanup() }
        #expect(model.agentDetail(.claude) == nil)
        #expect(model.agentDetail(.codex) == "Not installed. Install Codex, then press Check Again.")
        #expect(model.agentDetail(.opencode) == "Zeus couldn't check this agent. Press Check Again.")
        #expect(model.showsCheckAgain)
        controller.installed = [.claude, .codex, .opencode]
        model.refreshAvailability()
        #expect(!model.showsCheckAgain)
    }
}

/// D3-11: menu wording matches Settings and uses title case.
@MainActor struct R4cMenuCopyTests {
    @Test func hideItemsAreTitleCase() {
        #expect(MenuPresentation.hideForHour == "Hide for 1 Hour")
        #expect(MenuPresentation.hideUntilTomorrow == "Hide Until Tomorrow")
    }

    @Test func failedMenuMatchesTheStatusPanel() {
        let failed = ZeusManagedPresentation.make(.failed(reason: "Claude Code quit 5 times in 10 minutes, so Zeus stopped restarting it."),
                                                  agent: "Claude Code", folder: "~/Assistant", session: "zeus", now: Date())
        #expect(failed.title == "Couldn't keep it running")
        #expect(failed.menuStatus == "Zeus couldn't keep Claude Code running")
        #expect(failed.actions.first == .tryAgain)
        #expect(ZeusManagedPresentation.Action.tryAgain.menuTitle == ZeusManagedPresentation.Action.tryAgain.title)
    }
}

/// D3-12: requirement lines in Settings' words, and SETUP.md in step with the app's setup commands.
@MainActor struct R4cSetupCopyTests {
    @Test func requirementLinesNameWhatsMissingAndTheButton() {
        #expect(ManagedSessionController.requirementsMessage(missingTmux: false, missingAgent: nil) == nil)
        #expect(ManagedSessionController.requirementsMessage(missingTmux: false, missingAgent: .opencode)
                == "Not installed: OpenCode (the opencode command). Install it, then press Check Again.")
        #expect(ManagedSessionController.requirementsMessage(missingTmux: true, missingAgent: .codex)
                == "Not installed: tmux (brew install tmux) and Codex (the codex command). Install them, then press Check Again.")
        #expect(ManagedSessionError.invalidFolder.errorDescription?.contains("managed assistant") == false)
    }

    @Test func setupGuideMatchesTheAppsCommands() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let guide = try String(contentsOf: root.appendingPathComponent("docs/SETUP.md"), encoding: .utf8)
        for backend in AssistantBackend.allCases {
            for command in SetupCommands.steps(for: backend).compactMap(\.command) {
                #expect(guide.contains(command), "SETUP.md lacks \(command)")
            }
        }
        let openCodeRouting = try #require(SetupCommands.steps(for: .opencode).first { $0.title.hasPrefix("3.") })
        #expect(openCodeRouting.detail.contains("password field above"))
    }
}
