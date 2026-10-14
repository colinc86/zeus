import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct LiveManagedPermissionTests {
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func onlyZeusToolsArePreapprovedAndTheChosenModeIsKept(agent: AgentKind) async throws {
        let f = try ManagedFixture(agent: agent); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        let args = try #require(await f.host.commands.first?.arguments)
        switch agent {
        case .claude:
            let index = try #require(args.firstIndex(of: "--allowedTools"))
            #expect(Set(args[index + 1].split(separator: ",").map(String.init)) == Set(ZeusMCP.tools.map { "mcp__zeus__" + $0.name }))
            #expect(args.contains("manual") && !args.contains("--dangerously-skip-permissions"))
            #expect(!args.contains("--dangerously-load-development-channels") && !args.contains("--channels"))
        case .codex:
            let table = try #require(args.first { $0.hasPrefix("mcp_servers.zeus=") })
            for tool in ZeusMCP.tools { #expect(table.contains("\"\(tool.name)\"={approval_mode=\"approve\"}")) }
            #expect(args.contains("workspace-write") && args.contains("on-request"))
        case .opencode:
            let json = try #require(args.first { $0.hasPrefix("OPENCODE_CONFIG_CONTENT=") })
            let config = try JSONDecoder().decode(JSONValue.self, from: Data(json.dropFirst("OPENCODE_CONFIG_CONTENT=".count).utf8))
            #expect(config["permission"]?["*"] == "ask")
            for tool in ZeusMCP.tools { #expect(config["permission"]?["zeus_" + tool.name] == "allow") }
            #expect(config["permission"]?["bash"] == nil && config["permission"]?["edit"] == nil)
        case .other: Issue.record("Unsupported fixture")
        }
    }
}
