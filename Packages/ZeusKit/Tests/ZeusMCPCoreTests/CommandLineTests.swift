import Foundation
import Darwin
import Testing
import ZeusProtocol
@testable import ZeusMCPCore

@Test func commandLineDefaultsAndOverrides() throws {
    let defaults = try MCPCommandLineOptions.parse([])
    #expect(defaults.agent == .claude)
    #expect(defaults.socketPath == ZeusPaths.bridgeSocket.path)
    #expect(!defaults.showHelp)
    for agent in AgentKind.allCases {
        let options = try MCPCommandLineOptions.parse(["--agent", agent.rawValue, "--socket", "/tmp/zeus.sock"])
        #expect(options.agent == agent)
        #expect(options.socketPath == "/tmp/zeus.sock")
    }
    #expect(try MCPCommandLineOptions.parse(["--socket", "~/zeus.sock"]).socketPath == NSHomeDirectory() + "/zeus.sock")
    #expect(try MCPCommandLineOptions.parse(["--help"]).showHelp)
    #expect(try MCPCommandLineOptions.parse(["-h"]).showHelp)
}

@Test func commandLineRejectsInvalidInput() {
    for args in [["--agent"], ["--agent", "unknown"], ["--socket"], ["--socket", ""],
                 ["--socket", "--agent"], ["--socket", "bad\0path"], ["--unknown"], ["extra"]] {
        #expect(throws: MCPCommandLineError.self) { try MCPCommandLineOptions.parse(args) }
    }
}

@Test func parentIdentityIsCapturedOnceAndDoesNotDependOnTmux() throws {
    let start = try #require(AgentProcessIdentity.startTime(pid: Int(getpid())))
    #expect(start > 0 && start == AgentProcessIdentity.startTime(pid: Int(getpid())))
    #expect(AgentProcessIdentity.startTime(pid: 0) == nil)
    let a = MCPConfiguration(ppid: Int(getpid()), tmuxPane: "%1", parentStartTime: start)
    let b = MCPConfiguration(ppid: Int(getpid()), tmuxPane: "%2", parentStartTime: start)
    let client = BridgeHello.Client(name: "Test", version: "1")
    #expect(a.hello(client: client).sessionKey == b.hello(client: client).sessionKey)
    #expect(a.hello(client: client).parentStartTime == start)
}

@Test func tmuxSocketMetadataPreservesNamespaceAndNeverChangesIdentity() throws {
    #expect(MCPConfiguration.tmuxSocket(environment: "/tmp/a,b/server,42,0") == "/tmp/a,b/server")
    #expect(MCPConfiguration.tmuxSocket(environment: "invalid") == nil)
    #expect(MCPConfiguration.tmuxSocket(environment: "relative,42,0") == nil)
    let a = MCPConfiguration(ppid: 12, tmuxPane: "%0", parentStartTime: 34, tmuxSocketPath: "/tmp/a")
    let b = MCPConfiguration(ppid: 12, tmuxPane: "%0", parentStartTime: 34, tmuxSocketPath: "/tmp/b")
    let client = BridgeHello.Client(name: "Test", version: "1")
    #expect(a.hello(client: client).sessionKey == b.hello(client: client).sessionKey)
    #expect(a.hello(client: client).tmuxSocketPath == "/tmp/a")
    let frame = WireMessage.hello(a.hello(client: client))
    #expect(try ZeusJSON.decoder().decode(WireMessage.self, from: ZeusJSON.encoder().encode(frame)) == frame)
}
