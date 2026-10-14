import Foundation
import Testing
import Observation
import ZeusDesign
import ZeusProtocol
@testable import Zeus

/// R5c: docs/SETUP.md says what the app does (Round 4 audit A4N-1, A4N-2, A4N-4).
@MainActor struct R5cSetupGuideTests {
    static func guide() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("docs/SETUP.md"), encoding: .utf8)
    }

    /// A4N-2: Auto isn't "newest" for Claude Code, and it does pick Codex and OpenCode sessions.
    @Test func autoIsDescribedAsItChooses() throws {
        let guide = try Self.guide()
        #expect(!guide.contains("Auto (newest)"))
        #expect(!guide.contains("choose Codex and OpenCode sessions explicitly"))
        #expect(guide.contains("for Claude Code it prefers one Zeus can message directly"))
    }

    /// A4N-1: the guide's attach route is the status box's exact command, never a fixed `tmux attach -t zeus`.
    @Test func attachUsesTheStatusBoxCommand() throws {
        let guide = try Self.guide()
        #expect(!guide.contains("copy `tmux attach -t zeus`"))
        #expect(guide.contains("press **Copy** next to the command in the status box"))
        #expect(guide.contains("usually called `zeus`"))
    }

    /// A4N-4: OpenCode delivery goes to the chosen conversation through the server, not through its TUI prompt.
    @Test func openCodeIsServerDeliveryToTheChosenConversation() throws {
        let guide = try Self.guide()
        #expect(!guide.contains("added to its prompt and submitted"))
        #expect(!guide.contains("holds up messages until it's gone"))
        #expect(guide.contains("It never types into OpenCode's prompt"))
        #expect(guide.contains("as a new message in the conversation you chose"))
    }
}

/// A controller stand-in: no tmux, no agent configs, no processes.
@MainActor @Observable
private final class R5cController: ManagedSessionControlling {
    var managedStatus: ManagedSessionStatus = .failed(reason: "Codex stopped before it saved this conversation.")
    var managedTmuxSessionName: String?
    var managedAttachCommand: String?
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        [.init(id: "ask", title: "Ask", detail: "Asks first.", isUnrestricted: false, isDefault: true)]
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { nil }
    func startManagedSession() {}
    func stopManagedSession() {}
    func restartManagedSession() {}
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
}

/// A4D-6: Start New Conversation as a status-panel action goes through the usual confirmation.
@MainActor struct R5cNewConversationActionTests {
    @Test func actionAsksFirstAndFollowsCanStart() throws {
        let suite = "zeus-r5c-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let controller = R5cController()
        let model = ManagedAssistantModel(settings: AppSettings(defaults: defaults, userDirectory: nil), controller: { controller })
        model.update { $0.enabled = true; $0.folder = "/tmp/zeus-r5c-folder" }
        model.refreshAvailability()
        #expect(model.canStart && !model.disabledActions.contains(.newConversation))
        model.perform(.newConversation)
        #expect(model.confirmation == .newConversation)
        model.cancelConfirmation(); model.update { $0.folder = "" }
        #expect(model.disabledActions.contains(.newConversation))
        model.perform(.newConversation)
        #expect(model.confirmation == nil)
    }
}
