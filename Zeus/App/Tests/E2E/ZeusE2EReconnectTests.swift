import Darwin
import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor private final class ConnectionMonitor: BridgeServerDelegate {
    let runtime: ZeusRuntime
    var connects: [BridgeHello] = []
    var disconnects = 0
    init(_ runtime: ZeusRuntime) { self.runtime = runtime }
    func bridgeDidConnect(_ session: BridgeSession) { connects.append(session.hello); runtime.bridgeDidConnect(session) }
    func bridgeDidDisconnect(_ session: BridgeSession) { disconnects += 1; runtime.bridgeDidDisconnect(session) }
    func bridge(_ session: BridgeSession, callTool name: String, arguments: JSONValue) async -> ToolResult {
        await runtime.bridge(session, callTool: name, arguments: arguments)
    }
}

extension ZeusE2ETests {
    @Test func threeAgentParentsInOneFolderStayConnectedWithoutEvictionForThirtySeconds() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        f.runtime.server?.stop()
        let monitor = ConnectionMonitor(f.runtime)
        let server = BridgeServer(socketPath: f.runtime.socketPath)
        f.runtime.server = server
        try server.start(delegate: monitor)
        let cwd = f.directory.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        for _ in 0..<3 {
            let bridge = try E2EBridge(socketPath: f.runtime.socketPath, cwd: cwd, pane: "%same", separateAgentParent: true)
            f.children.append(bridge); try await bridge.initialize()
        }
        try await eventually { f.runtime.sessions.count == 3 }
        let keys = Set(f.runtime.sessions.map(\.sessionKey))
        #expect(keys.count == 3 && monitor.connects.count == 3)
        #expect(Set(monitor.connects.map(\.ppid)).count == 3)
        #expect(monitor.connects.allSatisfy { $0.parentStartTime > 0 && $0.tmuxPane == "%same" })
        try await Task.sleep(for: .seconds(30))
        #expect(monitor.connects.count == 3 && monitor.disconnects == 0)
        #expect(Set(f.runtime.sessions.map(\.sessionKey)) == keys)
        for (index, bridge) in f.children.enumerated() {
            let hello = try #require(monitor.connects.first { $0.ppid == Int(bridge.process.processIdentifier) })
            let result = try await bridge.call("zeus_say", ["text": .string("Parent \(index)")])
            let card = try #require(f.cards.card(id: try e2eString(result["card_id"])))
            #expect(card.sessionKey == hello.sessionKey && card.body == "Parent \(index)")
        }
        // Settings deduplicates only keys, so all three choices survive. Auto picks
        // the newest live channel session; explicit selection keeps its own parent.
        #expect(f.runtime.assistantTarget == f.runtime.sessions.first?.sessionKey)
        f.routing.assistantSessionKey = monitor.connects.first?.sessionKey
        #expect(f.runtime.assistantTarget == monitor.connects.first?.sessionKey)
    }

    @Test func sameParentReplacementGoesIdleWithoutFlappingUntilItsOwnToolCall() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        f.runtime.server?.stop()
        let monitor = ConnectionMonitor(f.runtime)
        let server = BridgeServer(socketPath: f.runtime.socketPath)
        f.runtime.server = server; try server.start(delegate: monitor)
        let older = try await f.bridge()
        let newer = try await f.bridge()
        try await eventually { monitor.connects.count == 2 && f.runtime.sessions.count == 1 }
        #expect(monitor.connects[0].sessionKey == monitor.connects[1].sessionKey)
        try await Task.sleep(for: .seconds(10))
        #expect(monitor.connects.count == 2 && f.runtime.sessions.count == 1)
        _ = try await newer.call("zeus_say", ["text": "New transport"])
        #expect(monitor.connects.count == 2)
        _ = try await older.call("zeus_say", ["text": "Explicit old-agent request"])
        try await eventually { monitor.connects.count == 3 }
        #expect(f.runtime.sessions.first?.id == monitor.connects[0].bridgeID)
        try await Task.sleep(for: .seconds(1))
        #expect(monitor.connects.count == 3)
    }

    @Test(arguments: [false, true])
    func sameBridgeSurvivesLongCleanQuitOrSIGKILLAndDifferentBuildRelaunch(_ crash: Bool) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/zp13_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = E2EProcessHost(directory: directory); defer { first.dispose() }
        try await first.start()
        let bridge = try E2EBridge(socketPath: directory.appendingPathComponent("bridge.sock").path, cwd: directory)
        defer { bridge.dispose() }
        try await bridge.initialize()
        let posted = try await bridge.call("zeus_say", ["text": "Before restart"])
        #expect(posted["card_id"] != nil)
        let configuration = crash ? "release" : "debug"
        try await E2EProcessHost.prepare(configuration: configuration)
        if crash { first.kill() } else { try await first.quit() }
        try await Task.sleep(for: .seconds(31))
        #expect(bridge.process.isRunning)
        let second = E2EProcessHost(directory: directory); defer { second.dispose() }
        // Release helper is hardened, without sandbox or entitlement changes.
        let resumed = ContinuousClock.now
        try await second.start(configuration: configuration)
        let result = try await bridge.call("zeus_say", ["text": "After restart"])
        #expect(ContinuousClock.now - resumed < .seconds(6))
        #expect(result["card_id"] != posted["card_id"])
        let snapshot = try ZeusJSON.decoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("cards.json")))
        #expect(snapshot["cards"]?[0]?["sessionKey"] == snapshot["cards"]?[1]?["sessionKey"])
        #expect(snapshot["cards"]?[2] == nil) // No replay of the first tool after reconnect.
        try await bridge.finish()
        try await second.quit()
    }
}
