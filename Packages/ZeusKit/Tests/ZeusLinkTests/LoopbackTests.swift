import Darwin
import Foundation
import Synchronization
import Testing
import ZeusProtocol
@testable import ZeusLink

private enum TestError: Error { case deadline }

@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TestError.deadline }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor private final class Delegate: BridgeServerDelegate {
    var connected: [BridgeSession] = []
    var disconnected: [UUID] = []
    var calls: [(String, JSONValue)] = []
    var pushes: [AgentPush] = []
    var delay: Duration = .zero
    func bridgeDidConnect(_ session: BridgeSession) { connected.append(session) }
    func bridgeDidDisconnect(_ session: BridgeSession) { disconnected.append(session.id) }
    func bridge(_ session: BridgeSession, callTool name: String, arguments: JSONValue) async -> ToolResult {
        calls.append((name, arguments))
        if delay != .zero { try? await Task.sleep(for: delay) }
        return ToolResult(text: #"{"card_id":"c_12345678"}"#, structured: ["card_id": "c_12345678"])
    }
}

private func temporarySocket() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp/zeus_" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("bridge.sock")
}
private func hello(version: Int = wireVersion, cwd: String = "/test", pane: String? = "%5") -> BridgeHello {
    .init(wireVersion: version, agent: .claude, pid: Int(getpid()), ppid: Int(getppid()), cwd: cwd,
          client: .init(name: "Test MCP", version: "1"), capabilities: .init(channel: true), tmuxPane: pane, parentStartTime: 123)
}

@Test @MainActor func socketLoopback() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let client = BridgeClient(socketPath: socket.path)
    do {
        let greeting = hello()
        let welcome = try await client.start(hello: greeting, onPush: { push in
            await MainActor.run { delegate.pushes.append(push) }
            try? await client.reportPushWritten(deliveryID: push.deliveryID)
        })
        #expect(welcome.wireVersion == 1)
        #expect(welcome.sessionKey == "claude:/test#\(getppid()).123")
        try await eventually { delegate.connected.count == 1 }
        let session = try #require(delegate.connected.first)
        #expect(session.id == greeting.bridgeID)
        #expect(session.hello == greeting)
        let result = try await client.callTool(name: "zeus_say", arguments: ["text": "Hello ⚡"])
        #expect(result.structured?["card_id"] == "c_12345678")
        #expect(delegate.calls.count == 1)
        #expect(delegate.calls.first?.0 == "zeus_say")
        #expect(delegate.calls.first?.1 == ["text": "Hello ⚡"])
        let push = AgentPush(deliveryID: "d_12345678", content: "Reply: Yes", meta: ["kind": "reply", "delivery_id": "d_12345678"])
        try await session.push(push)
        #expect(delegate.pushes == [push])
        await client.stop()
        try await eventually { delegate.disconnected == [greeting.bridgeID] }
        await #expect(throws: BridgeLinkError.disconnected) { try await session.push(push) }
    } catch { await client.stop(); throw error }
}

@Test @MainActor func versionMismatchReturnsErrorAndCloses() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    let raw = try await SocketChannel.connect(path: socket.path)
    defer { raw.close() }
    try await raw.send(.hello(hello(version: 99)))
    var iterator = raw.messages.makeAsyncIterator()
    let message = try await iterator.next()
    if case .error(let error) = message { #expect(error.message.contains("wireVersion")) }
    else { Issue.record("Expected version error") }
    #expect(try await iterator.next() == nil)
    #expect(delegate.connected.isEmpty)
}

@Test @MainActor func missingAgentStartTimeReturnsUpgradeGuidanceWithoutRegistering() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    let raw = try await SocketChannel.connect(path: socket.path)
    defer { raw.close() }
    var greeting = hello(); greeting.parentStartTime = 0
    try await raw.send(.hello(greeting))
    var iterator = raw.messages.makeAsyncIterator()
    if case .error(let error) = try await iterator.next() {
        #expect(error.message.contains("restart the agent's zeus-mcp"))
    } else { Issue.record("Expected identity upgrade error") }
    #expect(try await iterator.next() == nil)
    #expect(delegate.connected.isEmpty)
}

@Test @MainActor func rejectsNonHelloFirstMessage() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    let raw = try await SocketChannel.connect(path: socket.path)
    defer { raw.close() }
    try await raw.send(.toolCall(.init(name: "zeus_say")))
    var iterator = raw.messages.makeAsyncIterator()
    if case .error(let error) = try await iterator.next() { #expect(error.message.contains("hello")) }
    else { Issue.record("Expected handshake error") }
    #expect(try await iterator.next() == nil)
    #expect(delegate.connected.isEmpty)
}

@Test @MainActor func newestSessionWinsAndPendingPushFailsOnDisconnect() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    // Raw peers do not automatically reconnect and compete again for the key.
    let first = try await SocketChannel.connect(path: socket.path)
    defer { first.close() }
    let firstHello = hello()
    try await first.send(.hello(firstHello))
    var firstMessages = first.messages.makeAsyncIterator()
    if case .welcome = try await firstMessages.next() { } else { Issue.record("Expected welcome") }
    try await eventually { delegate.connected.count == 1 }
    let session = try #require(delegate.connected.first)
    let pending = Task { try await session.push(.init(deliveryID: "d_pending1", content: "Hello")) }
    if case .push = try await firstMessages.next() { } else { Issue.record("Expected push") }
    let second = try await SocketChannel.connect(path: socket.path)
    defer { second.close() }
    let secondHello = hello()
    try await second.send(.hello(secondHello))
    var secondMessages = second.messages.makeAsyncIterator()
    if case .welcome = try await secondMessages.next() { } else { Issue.record("Expected welcome") }
    try await eventually { delegate.connected.count == 2 && delegate.disconnected.contains(firstHello.bridgeID) }
    #expect(delegate.connected.last?.id == secondHello.bridgeID)
    await #expect(throws: BridgeLinkError.disconnected) { try await pending.value }
    if case .superseded(let notice) = try await firstMessages.next() {
        #expect(notice.sessionKey == firstHello.sessionKey)
    } else { Issue.record("Expected explicit superseded notice") }
    #expect(try await firstMessages.next() == nil)
    second.close()
    try await eventually { delegate.disconnected.count == 2 }
}

@Test @MainActor func pushTimesOutWithoutWrittenReceipt() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    let client = BridgeClient(socketPath: socket.path)
    do {
        _ = try await client.start(hello: hello(), onPush: { push in await MainActor.run { delegate.pushes.append(push) } })
        try await eventually { delegate.connected.count == 1 }
        let session = try #require(delegate.connected.first)
        let start = ContinuousClock.now
        await #expect(throws: BridgeLinkError.timeout) { try await session.push(.init(deliveryID: "d_timeout1", content: "Hello")) }
        #expect(ContinuousClock.now - start >= .seconds(5))
        #expect(delegate.pushes.count == 1)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test @MainActor func clientReconnectsAndCallsAreNotReplayed() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    delegate.delay = .seconds(1)
    try server.start(delegate: delegate)
    let client = BridgeClient(socketPath: socket.path)
    do {
        let greeting = hello()
        _ = try await client.start(hello: greeting, onPush: { _ in })
        let pending = Task { try await client.callTool(name: "zeus_ask", arguments: ["text": "Question"]) }
        try await eventually { delegate.calls.count == 1 }
        server.stop()
        await #expect(throws: BridgeLinkError.disconnected) { try await pending.value }
        try await eventually { delegate.disconnected.count == 1 }
        #expect(await client.welcome == nil)
        try server.start(delegate: delegate)
        try await eventually { delegate.connected.count == 2 }
        #expect(delegate.connected.last?.sessionKey == greeting.sessionKey)
        #expect(delegate.connected.last?.id == greeting.bridgeID)
        #expect(delegate.calls.count == 1)
        delegate.delay = .zero
        _ = try await client.callTool(name: "zeus_list_characters")
        #expect(delegate.calls.count == 2)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test @MainActor func timeoutAndCancellationReleasePendingCalls() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    delegate.delay = .seconds(1)
    try server.start(delegate: delegate)
    let client = BridgeClient(socketPath: socket.path)
    do {
        _ = try await client.start(hello: hello(), onPush: { _ in })
        await #expect(throws: BridgeLinkError.timeout) {
            try await client.callTool(name: "zeus_ask", timeout: .milliseconds(20))
        }
        let call = Task { try await client.callTool(name: "zeus_ask") }
        try await eventually { delegate.calls.count == 2 }
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        delegate.delay = .zero
        #expect(try await client.callTool(name: "zeus_say").isError == false)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test @MainActor func socketPathSafetyAndListenerOwnership() throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let delegate = Delegate()
    #expect(throws: BridgeLinkError.invalidSocketPath) { try BridgeServer(socketPath: String(repeating: "a", count: 200)).start(delegate: delegate) }
    #expect(throws: BridgeLinkError.invalidSocketPath) { try BridgeServer(socketPath: "bad\0path").start(delegate: delegate) }
    try Data("keep me".utf8).write(to: socket)
    #expect(throws: BridgeLinkError.socketAlreadyExists) { try BridgeServer(socketPath: socket.path).start(delegate: delegate) }
    #expect(try String(contentsOf: socket, encoding: .utf8) == "keep me")
    try FileManager.default.removeItem(at: socket)
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    try server.start(delegate: delegate)
    #expect(throws: BridgeLinkError.socketAlreadyExists) { try BridgeServer(socketPath: socket.path).start(delegate: delegate) }
    #expect(throws: (any Error).self) { try server.start(delegate: delegate) }
}

@Test @MainActor func initialConnectionFailureCanBeRetried() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let client = BridgeClient(socketPath: socket.path)
    await #expect(throws: (any Error).self) { try await client.start(hello: hello(), onPush: { _ in }) }
    #expect(await client.welcome == nil)
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    do {
        let welcome = try await client.start(hello: hello(), onPush: { _ in })
        #expect(welcome.sessionKey == "claude:/test#\(getppid()).123")
        #expect(try await client.callTool(name: "zeus_list_characters").isError == false)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test @MainActor func longRunningToolDoesNotBlockPushReceipts() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    delegate.delay = .seconds(1)
    try server.start(delegate: delegate)
    let client = BridgeClient(socketPath: socket.path)
    do {
        _ = try await client.start(hello: hello(), onPush: { push in try? await client.reportPushWritten(deliveryID: push.deliveryID) })
        let call = Task { try await client.callTool(name: "zeus_ask", arguments: ["text": "Question"]) }
        try await eventually { delegate.calls.count == 1 }
        let session = try #require(delegate.connected.first)
        let start = ContinuousClock.now
        try await session.push(.init(deliveryID: "d_12345678", content: "Message"))
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(try await call.value.isError == false)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test @MainActor func pushCancellationDoesNotPoisonTheConnection() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    let client = BridgeClient(socketPath: socket.path)
    do {
        _ = try await client.start(hello: hello(), onPush: { push in await MainActor.run { delegate.pushes.append(push) } })
        try await eventually { delegate.connected.count == 1 }
        let session = try #require(delegate.connected.first)
        let pending = Task { try await session.push(.init(deliveryID: "d_12345678", content: "Message")) }
        try await eventually { delegate.pushes.count == 1 }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        // A late receipt after cancellation must be harmless.
        try await client.reportPushWritten(deliveryID: "d_12345678")
        #expect(try await client.callTool(name: "zeus_say").isError == false)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test @MainActor func staleSocketIsReclaimed() throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let fd = try newSocket()
    var address = try socketAddress(socket.path)
    let bound = withAddress(&address) { Darwin.bind(fd, $0, $1) }
    Darwin.close(fd)
    try #require(bound == 0)
    #expect(FileManager.default.fileExists(atPath: socket.path))
    let server = BridgeServer(socketPath: socket.path)
    defer { server.stop() }
    let delegate = Delegate()
    try server.start(delegate: delegate)
    #expect((try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test @MainActor func stalledWelcomeTimesOutAndLaterStartCanRecover() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let stalled = try ListeningSocket(path: socket.path)
    let accepted = Mutex<[SocketChannel]>([])
    stalled.run { channel in accepted.withLock { $0.append(channel) } }
    defer { stalled.stop(); accepted.withLock { $0.forEach { $0.close() } } }
    let client = BridgeClient(socketPath: socket.path)
    do {
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await client.start(hello: hello(), onPush: { _ in }) }
        #expect(ContinuousClock.now - start < .seconds(6))
        #expect(await client.welcome == nil)
        stalled.stop(); accepted.withLock { $0.forEach { $0.close() } }
        let server = BridgeServer(socketPath: socket.path); defer { server.stop() }
        let delegate = Delegate(); try server.start(delegate: delegate)
        _ = try await client.start(hello: hello(), onPush: { _ in })
        #expect(try await client.callTool(name: "zeus_say").isError == false)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test @MainActor func sameBridgeIDTransportReplacementIsNotSupersededEviction() async throws {
    let socket = try temporarySocket()
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let server = BridgeServer(socketPath: socket.path); defer { server.stop() }
    let delegate = Delegate(); try server.start(delegate: delegate)
    let first = try await SocketChannel.connect(path: socket.path); defer { first.close() }
    let greeting = hello(); try await first.send(.hello(greeting))
    var messages = first.messages.makeAsyncIterator()
    _ = try await messages.next()
    let second = try await SocketChannel.connect(path: socket.path); defer { second.close() }
    try await second.send(.hello(greeting))
    var replacement = second.messages.makeAsyncIterator(); _ = try await replacement.next()
    try await eventually { delegate.connected.count == 2 }
    #expect(try await messages.next() == nil) // No superseded notice for the same bridge.
    #expect(delegate.disconnected.isEmpty)
}
