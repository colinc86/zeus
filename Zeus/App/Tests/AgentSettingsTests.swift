import Foundation
import Testing
import ZeusDesign
@testable import Zeus

@MainActor
struct AgentSettingsTests {
    @Test func backendDefaultsAndOverridesPersist() throws {
        let suite = "zeus-agent-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(settings.backend == .claude)
        #expect(settings.deliveryMethod == .channel)
        settings.backend = .codex
        #expect(settings.deliveryMethod == .tmux)
        settings.backend = .opencode
        #expect(settings.deliveryMethod == .opencode)
        settings.deliveryMethod = .polling
        settings.backend = .opencode
        #expect(settings.deliveryMethod == .polling)
        settings.openCodeURLText = "http://127.0.0.1:4567"
        settings.fontChoice = .system
        settings.assistantSessionKey = "codex:/test#%3"
        settings.setTmuxTarget("%3", socketPath: "/tmp/agent-test.sock")
        let loaded = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(loaded.backend == .opencode)
        #expect(loaded.deliveryMethod == .polling)
        #expect(loaded.tmuxTarget == "%3" && loaded.tmuxTargetSocketPath == AppSettings.normalizedTmuxSocket("/tmp/agent-test.sock"))
        #expect(loaded.openCodeBaseURL == URL(string: "http://127.0.0.1:4567"))
        #expect(loaded.fontChoice == .system)
        #expect(loaded.assistantSessionKey == settings.assistantSessionKey)
        loaded.backend = .claude
        #expect(loaded.deliveryMethod == .channel)
    }

    @Test func missingDeliverySettingUsesSavedBackendDefaultAndInvalidValuesFallBack() throws {
        let suite = "zeus-agent-default-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "agent.backend")
        #expect(AppSettings(defaults: defaults, userDirectory: nil).deliveryMethod == .tmux)
        defaults.set("bad", forKey: "agent.backend")
        defaults.set("bad", forKey: "agent.deliveryMethod")
        defaults.set("bad", forKey: "appearance.font")
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(settings.backend == .claude)
        #expect(settings.deliveryMethod == .channel)
        #expect(settings.fontChoice == .pixel)
    }

    @Test func openCodeURLValidationRetainsEditableText() throws {
        let suite = "zeus-url-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        for invalid in ["", "localhost:4096", "file:///tmp/server", "https:", "http://localhost/?query=1", "https://localhost/#fragment"] {
            settings.openCodeURLText = invalid
            #expect(settings.openCodeBaseURL == nil)
            #expect(settings.openCodeURLText == invalid)
        }
        settings.openCodeURLText = " https://localhost:4096/api "
        #expect(settings.openCodeBaseURL == URL(string: "https://localhost:4096/api"))
    }

    @Test func parsesTmuxPanesIncludingPathsWithSpacesAndFiltersDuplicates() {
        let output = "%3 main:1.0 codex /Users/me/Local Documents/Zeus\n%4 work:0.2 zsh /tmp\n%3 duplicate:0.0 bash /tmp\n"
        let panes = TmuxPane.parse(output)
        #expect(panes.count == 2)
        #expect(panes.first == TmuxPane(id: "%3", location: "main:1.0", command: "codex", path: "/Users/me/Local Documents/Zeus"))
        #expect(panes.last?.command == "zsh")
        #expect(panes.first?.label.contains("Local Documents") == true)
    }

    @Test func malformedTmuxLinesAndEmptyOutputAreIgnored() {
        #expect(TmuxPane.parse("").isEmpty)
        #expect(TmuxPane.parse("\nnot a pane\n% main:1.0 zsh /tmp\n%abc main:0.0 zsh /tmp\n%2 invalid zsh /tmp\n%3 main:0.0 zsh\n").isEmpty)
    }

    @Test func setupCommandsTreatExecutablePathAsData() throws {
        let path = "/Users/O'Brien/Zeus $HOME `touch nope`.app/Contents/MacOS/zeus-mcp"
        let command = SetupCommands.configuration(for: .claude, bridgePath: path)
        #expect(command.hasPrefix("claude mcp add -s user zeus -- '/Users/O'\\''Brien/"))
        #expect(command.hasSuffix("' --agent claude"))
        #expect(SetupCommands.configuration(for: .codex, bridgePath: "/Applications/Zeus.app/Contents/MacOS/zeus-mcp") == "codex mcp add zeus -- '/Applications/Zeus.app/Contents/MacOS/zeus-mcp' --agent codex")
        let object = try #require(JSONSerialization.jsonObject(with: Data(SetupCommands.configuration(for: .opencode, bridgePath: path).utf8)) as? [String: Any])
        let mcp = try #require(object["mcp"] as? [String: Any])
        let zeus = try #require(mcp["zeus"] as? [String: Any])
        #expect(zeus["command"] as? [String] == [path, "--agent", "opencode"])
        #expect(zeus["type"] as? String == "local")
    }
}
