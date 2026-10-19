import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct MenuPickerIntegrationTests {
    private func settings() throws -> (String, UserDefaults, AppSettings) {
        let suite = TestDefaults.suite("zeus-menu-picker")
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (suite, defaults, AppSettings(defaults: defaults, userDirectory: nil))
    }
    @Test func assistantChoicesKeepTheExplicitOfflineSelectionAndDistinctLiveIDs() throws {
        let (suite, defaults, settings) = try settings(); defer { defaults.removePersistentDomain(forName: suite) }
        let offline = "claude:/work/Website#101.1000"
        settings.assistantSessionKey = offline
        let sessions = ["102.1000", "103.1000"].map {
            ConnectedSession(id: UUID(), sessionKey: "claude:/work/Website#\($0)", agent: .claude, cwd: "/work/Website", clientName: nil,
                supportsChannel: false, tmuxPane: nil, connectedAt: Date())
        }
        settings.updateSessionLabels(sessions)
        let choices = AssistantSessionPicker.choices(settings: settings, sessions: sessions)
        #expect(choices.count == 3 && choices.first?.id == offline && choices.first?.title.contains("offline") == true)
        #expect(Set(choices.map(\.id)).count == 3)
        #expect(settings.assistantSessionKey == offline)
    }
    @Test func paneChoicesPreserveSavedTargetsAndPersistTheDisplayedNamespace() throws {
        let (suite, defaults, settings) = try settings(); defer { defaults.removePersistentDomain(forName: suite) }
        let pane = TmuxPane(id: "%0", location: "fixture:0.0", command: "cat", path: "/fixture", socketPath: "/tmp/displayed-server.sock")
        let choices = AgentSettingsView.paneChoices(panes: [pane], saved: "%9")
        #expect(choices.map(\.id) == ["%0", "%9"] && choices.last?.title.contains("Saved pane") == true)
        AgentSettingsView.selectPane("%0", panes: [pane], socketPath: "/tmp/new-auto-server.sock", settings: settings)
        #expect(settings.tmuxTarget == "%0" && settings.tmuxTargetSocketPath == AppSettings.normalizedTmuxSocket(pane.socketPath))
        let savedSocket = settings.tmuxTargetSocketPath
        AgentSettingsView.selectPane("%0", panes: [], socketPath: savedSocket, settings: settings)
        #expect(settings.tmuxTarget == "%0" && settings.tmuxTargetSocketPath == savedSocket)
        AgentSettingsView.selectPane(nil, panes: [pane], socketPath: pane.socketPath, settings: settings)
        #expect(settings.tmuxTarget == "%0" && settings.tmuxTargetSocketPath == savedSocket)
        settings.setTmuxTarget(nil, socketPath: nil) // Clearing the manual field is explicit.
        #expect(settings.tmuxTarget == nil && settings.tmuxTargetSocketPath == nil)
    }
    @Test func nativeConversationMenuKeepsMissingIDsAndRejectsSelectionsFromAnOldServerList() throws {
        let (suite, defaults, settings) = try settings(); defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = try #require(URL(string: "http://server-a.test:4096"))
        settings.openCodeURLText = endpoint.absoluteString
        let a = OpenCodeNativeSession(id: "ses_A", title: "Assistant", directory: "/work/Website")
        let b = OpenCodeNativeSession(id: "ses_B", title: "Assistant", directory: "/work/Website")
        let choices = OpenCodeSessionPicker.choices(sessions: [a, b], selected: "ses_missing")
        #expect(choices.count == 3 && choices[0].title != choices[1].title && choices.last?.title.contains("ses_missing") == true)
        let key = "opencode:/work/Website#101.1000"
        #expect(OpenCodeSessionPicker.select(a.id, for: key, sessions: [a, b], endpoint: endpoint, settings: settings))
        #expect(settings.openCodeSessionID(for: key) == a.id)
        settings.openCodeURLText = "http://server-b.test:4096"
        #expect(!OpenCodeSessionPicker.select(b.id, for: key, sessions: [a, b], endpoint: endpoint, settings: settings))
        settings.openCodeURLText = endpoint.absoluteString
        #expect(settings.openCodeSessionID(for: key) == a.id)
        #expect(!OpenCodeSessionPicker.select(nil, for: key, sessions: [a, b], endpoint: endpoint, settings: settings))
        #expect(settings.openCodeSessionID(for: key) == a.id)
        settings.setOpenCodeSessionID(nil, for: key) // An explicit clear remains supported by Settings.
        #expect(settings.openCodeSessionID(for: key) == nil)
    }
}
