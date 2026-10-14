import Foundation
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor struct AutoSelectionPresentationTests {
    private func session(_ agent: AgentKind, _ folder: String, _ channel: Bool = false, process: Int? = nil) -> ConnectedSession {
        .init(id: UUID(), sessionKey: "\(agent.rawValue):\(folder)#\(process ?? (channel ? 101 : 202)).1000", agent: agent, cwd: folder,
              clientName: nil, supportsChannel: channel, tmuxPane: nil, connectedAt: Date())
    }
    @Test func autoNamesTheOlderDirectSessionEvenWhileANewerOneIsExplicitlySelected() throws {
        let suite = "zeus-auto-copy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let newest = session(.claude, "/fixture/new"), direct = session(.claude, "/fixture/old", true)
        let sessions = [newest, direct]; settings.updateSessionLabels(sessions)
        #expect(settings.selectedAssistant(in: sessions)?.sessionKey == direct.sessionKey)
        let title = AssistantSessionPicker.autoTitle(settings: settings, sessions: sessions)
        #expect(title == ZeusSettingsCopy.Auto.title(current: settings.sessionLabels.label(direct.sessionKey)))
        #expect(title.contains("old") && !title.contains("newest"))
        settings.assistantSessionKey = newest.sessionKey
        #expect(settings.selectedAssistant(in: sessions)?.sessionKey == newest.sessionKey)
        #expect(AssistantSessionPicker.autoTitle(settings: settings, sessions: sessions) == title)
        #expect(settings.assistantSessionKey == newest.sessionKey)
    }
    @Test(arguments: [AgentKind.codex, .opencode])
    func autoUsesTheChosenAgentAndShowsItsNewestFolder(agent: AgentKind) throws {
        let suite = "zeus-auto-backend-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.backend = try #require(AssistantBackend(rawValue: agent.rawValue))
        let newest = session(agent, "/fixture/new"), older = session(agent, "/fixture/old"), claude = session(.claude, "/other", true)
        let sessions = [claude, newest, older]; settings.updateSessionLabels(sessions)
        #expect(settings.automaticAssistant(in: sessions)?.sessionKey == newest.sessionKey)
        #expect(AssistantSessionPicker.autoTitle(settings: settings, sessions: sessions).contains("new"))
        #expect(AssistantSessionPicker.autoTitle(settings: settings, sessions: []) == "Auto")
    }
    @Test func manualUnmappedOpenCodeFolderRepresentativeDoesNotChangeTheAutoPreview() throws {
        let suite = "zeus-auto-folder-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil); settings.backend = .opencode
        let newest = session(.opencode, "/shared")
        let old = session(.opencode, "/shared", process: 101)
        settings.assistantSessionKey = old.sessionKey
        #expect(settings.assistantCandidates([newest, old]).first?.sessionKey == old.sessionKey)
        #expect(settings.automaticAssistant(in: [newest, old])?.sessionKey == newest.sessionKey)
        #expect(settings.assistantSessionKey == old.sessionKey)
    }
}
