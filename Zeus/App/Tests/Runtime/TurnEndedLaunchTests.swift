import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct TurnEndedLaunchTests {
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func managedFreshAndResumeCarryTheSameLaunchOnlyHook(_ agent: AgentKind) async throws {
        let f = try ManagedFixture(agent: agent); defer { f.cleanup() }
        if agent == .opencode { await f.finder.setID("ses_hook") }
        f.controller.activate(); try await f.settle()
        f.controller.restartManagedSession(); try await f.settle()
        let commands = await f.host.commands
        #expect(commands.count == 2)
        for command in commands {
            switch agent {
            case .claude:
                let i = try #require(command.arguments.firstIndex(of: "--settings"))
                let settings = try ZeusJSON.decoder().decode(JSONValue.self, from: Data(command.arguments[i + 1].utf8))
                #expect(settings["hooks"]?["Stop"] != nil && settings["hooks"]?["StopFailure"] != nil)
                #expect(settings["permissions"] == nil && settings["disableAllHooks"] == nil)
            case .codex:
                #expect(command.arguments.contains { $0.hasPrefix("notify=[") && $0.contains("--turn-ended") })
            case .opencode:
                let entry = try #require(command.arguments.first { $0.hasPrefix("OPENCODE_CONFIG_CONTENT=") })
                let json = try ZeusJSON.decoder().decode(JSONValue.self, from: Data(entry.dropFirst("OPENCODE_CONFIG_CONTENT=".count).utf8))
                let text = try e2eString(json["plugin"]?[0])
                let url = try #require(URL(string: text))
                #expect(url.isFileURL && url.path.hasPrefix(f.folder.path))
                #expect(try String(contentsOf: url, encoding: .utf8).contains("session.idle"))
            case .other: Issue.record("Unsupported fixture agent")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent(".claude/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent(".codex/config.toml").path))
        #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("opencode.json").path))
    }
    @Test func setupCommandsCarryHooksAsShellDataWithoutChangingRegistration() async throws {
        let path = "/fixture/Zeus's app/zeus-mcp", socket = "/fixture/socket's path"
        for backend in AssistantBackend.allCases {
            let command = try #require(SetupCommands.steps(for: backend, bridgePath: path, socketPath: socket)[1].command)
            #expect(command.contains(backend == .opencode ? "--hook-settings" : "--turn-ended"))
            let result = try await FoundationProcessRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["-n", "-c", command], input: nil,
                environment: ["HOME": "/tmp", "PATH": "/usr/bin:/bin"])
            #expect(result.status == 0)
            #expect(!SetupCommands.configuration(for: backend, bridgePath: path).contains("--turn-ended"))
        }
    }
}
