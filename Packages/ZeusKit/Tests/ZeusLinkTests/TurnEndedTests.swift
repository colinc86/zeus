import Foundation
import Testing
import ZeusProtocol
@testable import ZeusLink

@MainActor private final class HookDelegate: BridgeServerDelegate {
    var connections = 0, disconnections = 0
    var events: [TurnEnded] = []
    var delay: Duration = .zero
    func bridgeDidConnect(_ session: BridgeSession) { connections += 1 }
    func bridgeDidDisconnect(_ session: BridgeSession) { disconnections += 1 }
    func bridge(_ session: BridgeSession, callTool name: String, arguments: JSONValue) async -> ToolResult { .init(text: "ok") }
    func bridgeTurnEnded(_ event: TurnEnded) async { events.append(event); try? await Task.sleep(for: delay) }
}

@MainActor struct TurnEndedLinkTests {
    @Test func oneShotCannotRegisterEvictOrDisconnectALiveBridge() async throws {
        let root = URL(fileURLWithPath: "/tmp/zhook_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("bridge.sock").path
        let delegate = HookDelegate(), server = BridgeServer(socketPath: socket)
        try server.start(delegate: delegate); defer { server.stop() }
        let client = BridgeClient(socketPath: socket); defer { Task { await client.stop() } }
        let hello = BridgeHello(agent: .claude, pid: 22, ppid: 21, cwd: "/fixture", client: .init(name: "Hook fixture", version: "1"), capabilities: .init(), parentStartTime: 123)
        _ = try await client.start(hello: hello, onPush: { _ in })
        let event = TurnEnded(agent: .claude, pid: 32, ppid: 21, cwd: "/fixture", ancestors: [.init(pid: 21, startTime: 123)], firedAt: Date().timeIntervalSince1970)
        try await TurnEndedClient.send(event, socketPath: socket)
        #expect(delegate.events == [event] && delegate.connections == 1 && delegate.disconnections == 0)
        #expect(try await client.callTool(name: "still connected").text == "ok")
    }

    @Test func aStalledHookDelegateHasABoundedClient() async throws {
        let root = URL(fileURLWithPath: "/tmp/zhook_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = HookDelegate(); delegate.delay = .seconds(1)
        let socket = root.appendingPathComponent("bridge.sock").path, server = BridgeServer(socketPath: socket)
        try server.start(delegate: delegate); defer { server.stop() }
        let event = TurnEnded(agent: .claude, pid: 32, ppid: 21, cwd: "/fixture", ancestors: [.init(pid: 21, startTime: 123)], firedAt: 1)
        let start = ContinuousClock.now
        await #expect(throws: BridgeLinkError.timeout) { try await TurnEndedClient.send(event, socketPath: socket, timeout: .milliseconds(50)) }
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
