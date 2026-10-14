import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import ZeusMCPCore

private enum TestError: Error { case deadline, outputFailed }

@MainActor private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw TestError.deadline }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor MemoryOutput: MCPOutput {
    var frames: [JSONValue] = []
    var started: [JSONValue] = []
    var blockChannels = false
    var blockID: JSONValue?
    var failWrites = false
    private var blocked: [CheckedContinuation<Void, Never>] = []

    func writeAndFlush(_ frame: Data) async throws {
        #expect(frame.last == 10)
        #expect(frame.filter { $0 == 10 }.count == 1)
        let json = try ZeusJSON.decoder().decode(JSONValue.self, from: frame)
        started.append(json)
        if (blockChannels && json["method"] == "notifications/claude/channel") || (blockID != nil && json["id"] == blockID) {
            await withCheckedContinuation { blocked.append($0) }
        }
        if failWrites { throw TestError.outputFailed }
        frames.append(json)
    }
    func response(_ id: JSONValue) -> JSONValue? { frames.first { $0["id"] == id } }
    func responses(_ id: JSONValue) -> [JSONValue] { frames.filter { $0["id"] == id } }
    func setBlockChannels() { blockChannels = true }
    func setBlockID(_ id: JSONValue) { blockID = id }
    func setFailWrites() { failWrites = true }
    func release() {
        blockChannels = false; blockID = nil
        let waiters = blocked; blocked.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor private final class Delegate: BridgeServerDelegate {
    var sessions: [BridgeSession] = []
    var disconnected: [UUID] = []
    var calls: [(String, JSONValue)] = []
    var completions: [(String, Bool)] = []
    func bridge(_ session: BridgeSession, finishedTool name: String, result: ToolResult, written: Bool) { completions.append((name, written)) }
    var heldNames: Set<String> = []
    var result = ToolResult(text: #"{"card_id":"c_12345678"}"#, structured: ["card_id": "c_12345678"])
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func bridgeDidConnect(_ session: BridgeSession) { sessions.append(session) }
    func bridgeDidDisconnect(_ session: BridgeSession) { disconnected.append(session.id) }
    func bridge(_ session: BridgeSession, callTool name: String, arguments: JSONValue) async -> ToolResult {
        calls.append((name, arguments))
        if heldNames.contains(name) { await withCheckedContinuation { waiters.append($0) } }
        return result
    }
    func resumeTools() {
        heldNames.removeAll()
        let current = waiters; waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

@MainActor private final class Fixture {
    let socket: URL
    let app: BridgeServer
    let delegate = Delegate()
    let input: AsyncThrowingStream<Data, any Error>.Continuation
    let output = MemoryOutput()
    let task: Task<Void, any Error>
    let configuration: MCPConfiguration

    init(startApp: Bool = true, agent: AgentKind = .claude, limit: Int = 4 * 1024 * 1024, receiptTimeout: Duration = .seconds(5)) throws {
        let directory = URL(fileURLWithPath: "/tmp/zmcp_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socket = directory.appendingPathComponent("bridge.sock")
        app = BridgeServer(socketPath: socket.path, resultReceiptTimeout: receiptTimeout)
        configuration = MCPConfiguration(agent: agent, socketPath: socket.path, cwd: "/assistant", pid: 123, ppid: 45,
                                         tmuxPane: "%7", version: "1.2.3", maximumFrameBytes: limit, parentStartTime: 123)
        if startApp { try app.start(delegate: delegate) }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        input = continuation
        let server = MCPServer(configuration: configuration)
        let output = self.output
        task = Task { try await server.run(input: stream, output: output) }
    }
    func send(_ json: JSONValue) throws {
        var data = try ZeusJSON.encoder().encode(json); data.append(10); input.yield(data)
    }
    func request(_ id: JSONValue, _ method: String, _ params: JSONValue = [:]) throws {
        try send(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params])
    }
    func initialize() async throws {
        try request(1, "initialize", ["protocolVersion": "2026-07-28", "capabilities": [:], "clientInfo": ["name": "Claude Test", "version": "2"]])
        try await eventually { await self.output.response(1) != nil }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }
    func response(_ id: JSONValue) async throws -> JSONValue {
        try await eventually { await self.output.response(id) != nil }
        return try #require(await output.response(id))
    }
    func finish() async throws {
        input.finish()
        await output.release()
        delegate.resumeTools()
        do { try await task.value }
        catch { app.stop(); try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()); throw error }
        app.stop()
        try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
    }
}

@Test @MainActor func initializeShapeLocalToolsAndHello() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        let response = try await fixture.response(1)
        #expect(response["jsonrpc"] == "2.0")
        #expect(response["id"] == 1)
        #expect(response["result"]?["protocolVersion"] == "2025-06-18")
        #expect(response["result"]?["serverInfo"] == ["name": "zeus", "version": "1.2.3"])
        #expect(response["result"]?["instructions"] == .string(ZeusMCP.instructions))
        #expect(response["result"]?["capabilities"] == ZeusMCP.capabilities(agent: .claude))
        try await eventually { fixture.delegate.sessions.count == 1 }
        let session = try #require(fixture.delegate.sessions.first)
        #expect(session.hello.bridgeID == fixture.configuration.bridgeID)
        #expect(session.hello.client == .init(name: "Claude Test", version: "2"))
        #expect(session.hello.pid == 123 && session.hello.ppid == 45)
        #expect(session.hello.cwd == "/assistant" && session.hello.tmuxPane == "%7")
        #expect(session.hello.capabilities.channel)
        #expect(session.sessionKey == "claude:/assistant#45.123")
        try fixture.request("list", "tools/list")
        #expect(try await fixture.response("list")["result"]?["tools"] == JSONValue.from(ZeusMCP.tools))
        try fixture.request("ping", "ping")
        #expect(try await fixture.response("ping")["result"] == [:])
        try fixture.send(["jsonrpc": "2.0", "method": "notifications/something_unknown"])
        try fixture.request(4, "not/a/method")
        #expect(try await fixture.response(4)["error"]?["code"] == -32601)
        #expect(await fixture.output.frames.count == 4)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func forwardedResultsAndToolErrors() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        try fixture.request("say", "tools/call", ["name": "zeus_say", "arguments": ["text": "Hello ⚡"]])
        let response = try await fixture.response("say")
        #expect(response["result"]?["content"] == [["type": "text", "text": .string(fixture.delegate.result.text)]])
        #expect(response["result"]?["structuredContent"] == ["card_id": "c_12345678"])
        #expect(response["result"]?["isError"] == false)
        #expect(fixture.delegate.calls.count == 1)
        #expect(fixture.delegate.calls.first?.0 == "zeus_say")
        #expect(fixture.delegate.calls.first?.1 == ["text": "Hello ⚡"])
        fixture.delegate.result = ToolResult(text: "Invalid card", isError: true)
        try fixture.request(3, "tools/call", ["name": "zeus_dismiss", "arguments": ["card_id": "missing"]])
        let error = try await fixture.response(3)
        #expect(error["result"]?["isError"] == true)
        #expect(error["result"]?["content"] == [["type": "text", "text": "Invalid card"]])
        #expect(error["result"]?["structuredContent"] == nil)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func appNotRunningStillListsToolsAndStartsLater() async throws {
    let fixture = try Fixture(startApp: false)
    do {
        try await fixture.initialize()
        try fixture.request(2, "tools/list")
        #expect(try await fixture.response(2)["result"]?["tools"] == JSONValue.from(ZeusMCP.tools))
        try fixture.request(3, "tools/call", ["name": "zeus_list_characters"])
        let error = try await fixture.response(3)
        #expect(error["result"]?["isError"] == true)
        #expect(error["result"]?["content"] == [["type": "text", "text": .string(ZeusMCP.appNotRunningText)]])
        try fixture.app.start(delegate: fixture.delegate)
        try await eventually { fixture.delegate.sessions.count == 1 }
        try fixture.request(4, "tools/call", ["name": "zeus_list_characters"])
        #expect(try await fixture.response(4)["result"]?["isError"] == false)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func channelNotificationMatchesExactlyAndReceiptsWaitForFlush() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        try await eventually { fixture.delegate.sessions.count == 1 }
        let session = try #require(fixture.delegate.sessions.first)
        await fixture.output.setBlockChannels()
        let push = AgentPush(deliveryID: "d_12345678", content: "Reply to \"Ready?\": Yes\nThanks", meta: [
            "kind": "reply", "delivery_id": "d_12345678", "card_id": "c_12345678", "option_id": "yes",
            "UPPER_09": "valid", "bad-key": "drop", "": "drop", "sp ace": "drop", "café": "drop"
        ])
        var received = false
        let pending = Task { try await session.push(push); received = true }
        try await eventually { await fixture.output.started.contains { $0["method"] == "notifications/claude/channel" } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!received)
        #expect(await fixture.output.frames.count == 1)
        await fixture.output.release()
        try await pending.value
        #expect(received)
        let frames = await fixture.output.frames
        #expect(frames.last == ["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": [
            "content": .string(push.content), "meta": ["kind": "reply", "delivery_id": "d_12345678", "card_id": "c_12345678", "option_id": "yes", "UPPER_09": "valid"]
        ]])
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func reconnectsAfterAppRestartWithSameIdentity() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        try await eventually { fixture.delegate.sessions.count == 1 }
        fixture.app.stop()
        try await eventually { fixture.delegate.disconnected.count == 1 }
        try fixture.request(2, "tools/call", ["name": "zeus_say", "arguments": ["text": "offline"]])
        #expect(try await fixture.response(2)["result"]?["isError"] == true)
        try fixture.app.start(delegate: fixture.delegate)
        try await eventually { fixture.delegate.sessions.count == 2 }
        #expect(fixture.delegate.sessions[0].sessionKey == fixture.delegate.sessions[1].sessionKey)
        #expect(fixture.delegate.sessions[0].id == fixture.delegate.sessions[1].id)
        try fixture.request(3, "tools/call", ["name": "zeus_say", "arguments": ["text": "online"]])
        #expect(try await fixture.response(3)["result"]?["isError"] == false)
        let session = try #require(fixture.delegate.sessions.last)
        try await session.push(.init(deliveryID: "d_12345678", content: "After restart"))
        #expect(await fixture.output.frames.last?["params"]?["content"] == "After restart")
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func learningNotificationContainsOnlyTheDigestOrMoment() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        try await eventually { fixture.delegate.sessions.count == 1 }
        let session = try #require(fixture.delegate.sessions.first)
        try await session.notifyLearning(.init(id: "l_today", kind: .digest, text: "A focused morning.\nBack after lunch."))
        try await eventually { await fixture.output.frames.contains { $0["method"] == "notifications/zeus/learning" } }
        let notification = try #require(await fixture.output.frames.first { $0["method"] == "notifications/zeus/learning" })
        #expect(notification == ["jsonrpc": "2.0", "method": "notifications/zeus/learning", "params": [
            "id": "l_today", "kind": "digest", "text": "A focused morning.\nBack after lunch."
        ]])
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func disconnectedToolCallBypassesAnOutstandingBackoff() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        try await eventually { fixture.delegate.sessions.count == 1 }
        fixture.app.stop()
        try await eventually { fixture.delegate.disconnected.count == 1 }
        // Multiple failed backoff cycles: next timer is substantially later than a tool kick.
        try await Task.sleep(for: .seconds(2))
        try fixture.app.start(delegate: fixture.delegate)
        let start = ContinuousClock.now
        try fixture.request(2, "tools/call", ["name": "zeus_say", "arguments": ["text": "Reconnect now"]])
        #expect(try await fixture.response(2)["result"]?["isError"] == false)
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(fixture.delegate.calls.count == 1)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func eofResolvesWaitingCallAndDoesNotBlockPing() async throws {
    let fixture = try Fixture()
    do {
        fixture.delegate.heldNames = ["zeus_ask"]
        try await fixture.initialize()
        try fixture.request(2, "tools/call", ["name": "zeus_ask", "arguments": ["text": "Wait for me"]])
        try await eventually { fixture.delegate.calls.count == 1 }
        try fixture.request(3, "ping")
        #expect(try await fixture.response(3)["result"] == [:])
        fixture.input.finish()
        try await fixture.task.value
        let response = try await fixture.response(2)
        #expect(response["result"]?["isError"] == true)
        #expect(await fixture.output.responses(2).count == 1)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func eofDuringResultFlushDoesNotProduceDuplicateResponses() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        await fixture.output.setBlockID(2)
        try fixture.request(2, "tools/call", ["name": "zeus_list_characters"])
        try await eventually { await fixture.output.started.contains { $0["id"] == 2 } }
        fixture.input.finish()
        await fixture.output.release()
        try await fixture.task.value
        #expect(await fixture.output.responses(2).count == 1)
        #expect(try await fixture.response(2)["result"]?["isError"] == false)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func nonClaudeCapabilitiesDoNotAdvertiseChannels() async throws {
    let fixture = try Fixture(agent: .codex)
    do {
        try await fixture.initialize()
        #expect(try await fixture.response(1)["result"]?["capabilities"] == ["tools": [:]])
        try await eventually { fixture.delegate.sessions.count == 1 }
        #expect(fixture.delegate.sessions.first?.hello.agent == .codex)
        #expect(fixture.delegate.sessions.first?.hello.capabilities.channel == false)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func malformedFramesAndInvalidRequestsRecover() async throws {
    let fixture = try Fixture(startApp: false)
    do {
        fixture.input.yield(Data("not json\n".utf8))
        fixture.input.yield(Data([0xff, 10]))
        try fixture.send([1, 2])
        try fixture.send(["jsonrpc": "1.0", "id": 2, "method": "ping"])
        try fixture.send(["jsonrpc": "2.0", "id": true, "method": "ping"])
        try fixture.request(3, "initialize")
        #expect(try await fixture.response(3)["error"]?["code"] == -32602)
        try await fixture.initialize()
        try fixture.request(4, "tools/call", ["name": "missing"])
        #expect(try await fixture.response(4)["error"]?["code"] == -32602)
        try fixture.request(5, "tools/call", ["name": "zeus_say", "arguments": []])
        #expect(try await fixture.response(5)["error"]?["code"] == -32602)
        let frames = await fixture.output.frames
        #expect(frames.prefix(2).allSatisfy { $0["error"]?["code"] == -32700 && $0["id"] == .null })
        #expect(frames.dropFirst(2).prefix(3).allSatisfy { $0["error"]?["code"] == -32600 })
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func partialUTF8AndMultipleMessagesPerChunk() async throws {
    let fixture = try Fixture(startApp: false)
    do {
        let message: JSONValue = ["jsonrpc": "2.0", "id": "⚡", "method": "ping"]
        var bytes = try ZeusJSON.encoder().encode(message); bytes.append(10)
        for byte in bytes { fixture.input.yield(Data([byte])) }
        #expect(try await fixture.response("⚡")["result"] == [:])
        fixture.input.yield(bytes + bytes)
        try await eventually { await fixture.output.responses("⚡").count == 3 }
        fixture.input.yield(Data("{unfinished".utf8))
        try await fixture.finish()
        #expect(await fixture.output.frames.last?["error"]?["code"] == -32700)
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func oversizedFrameIsBoundedAndRecovers() async throws {
    let fixture = try Fixture(startApp: false, limit: 128)
    do {
        fixture.input.yield(Data(repeating: 65, count: 256))
        fixture.input.yield(Data("\n".utf8))
        try fixture.request(9, "ping")
        #expect(try await fixture.response(9)["result"] == [:])
        #expect(await fixture.output.frames.first?["error"]?["code"] == -32700)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func outputFailureStopsEvenWhenInputRemainsOpen() async throws {
    let fixture = try Fixture()
    do {
        try await fixture.initialize()
        try await eventually { fixture.delegate.sessions.count == 1 }
        await fixture.output.setFailWrites()
        let session = try #require(fixture.delegate.sessions.first)
        let push = Task { try await session.push(.init(deliveryID: "d_12345678", content: "Output fails")) }
        await #expect(throws: TestError.outputFailed) { try await fixture.task.value }
        await #expect(throws: (any Error).self) { try await push.value }
        #expect(await fixture.output.frames.count == 1)
        try? await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func channelPushWaitsUntilClientInitializedNotification() async throws {
    let fixture = try Fixture()
    do {
        try fixture.request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Test", "version": "1"]])
        _ = try await fixture.response(1)
        try await eventually { fixture.delegate.sessions.count == 1 }
        let session = try #require(fixture.delegate.sessions.first)
        let pending = Task { try await session.push(.init(deliveryID: "d_12345678", content: "Before initialized")) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.output.frames.count == 1)
        try fixture.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try await pending.value
        #expect(await fixture.output.frames.last?["params"]?["content"] == "Before initialized")
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@Test @MainActor func eofUnblocksPushWaitingForClientInitialization() async throws {
    let fixture = try Fixture()
    do {
        try fixture.request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Test", "version": "1"]])
        _ = try await fixture.response(1)
        try await eventually { fixture.delegate.sessions.count == 1 }
        let session = try #require(fixture.delegate.sessions.first)
        let pending = Task { try await session.push(.init(deliveryID: "d_12345678", content: "Before initialized")) }
        try await Task.sleep(for: .milliseconds(30))
        fixture.input.finish()
        try await fixture.task.value
        await #expect(throws: BridgeLinkError.disconnected) { try await pending.value }
        #expect(await fixture.output.frames.count == 1)
        try await fixture.finish()
    } catch { try? await fixture.finish(); throw error }
}

@MainActor struct ToolResultReceiptTests {
    @Test func stdoutReceiptWaitsForFlush() async throws {
        let f = try Fixture(); defer { f.input.finish() }
        try await f.initialize()
        await f.output.setBlockID(42)
        try f.request(42, "tools/call", ["name": "zeus_get_responses", "arguments": [:]])
        try await eventually { await f.output.started.contains { $0["id"] == 42 } }
        #expect(f.delegate.completions.isEmpty)
        await f.output.release()
        try await eventually { f.delegate.completions.count == 1 }
        #expect(f.delegate.completions.first?.1 == true)
        f.input.finish(); try await f.task.value
    }
    @Test func failedOutputNeverCommitsConsumption() async throws {
        let f = try Fixture(); defer { f.input.finish() }
        try await f.initialize()
        await f.output.setFailWrites()
        try f.request(42, "tools/call", ["name": "zeus_get_responses", "arguments": [:]])
        do { try await f.task.value; Issue.record("Expected output failure") } catch { }
        try await eventually { !f.delegate.completions.isEmpty }
        #expect(f.delegate.completions.allSatisfy { !$0.1 })
    }
    @Test func appDisconnectDuringOutputDoesNotTerminateMCP() async throws {
        let f = try Fixture(); defer { f.input.finish() }
        try await f.initialize()
        await f.output.setBlockID(42)
        try f.request(42, "tools/call", ["name": "zeus_get_responses", "arguments": [:]])
        try await eventually { await f.output.started.contains { $0["id"] == 42 } }
        f.app.stop()
        try await eventually { !f.delegate.disconnected.isEmpty }
        await f.output.release()
        try await eventually { await f.output.response(42) != nil }
        try f.request(43, "ping")
        try await eventually { await f.output.response(43) != nil }
        f.input.finish(); try await f.task.value
        #expect(f.delegate.completions.allSatisfy { !$0.1 })
    }

    @Test func unconsumedResultExpiresWithoutClosingTheBridge() async throws {
        let f = try Fixture(receiptTimeout: .milliseconds(50)); defer { f.input.finish() }
        try await f.initialize()
        await f.output.setBlockID(42)
        try f.request(42, "tools/call", ["name": "zeus_get_responses", "arguments": [:]])
        try await eventually { await f.output.started.contains { $0["id"] == 42 } }
        try await eventually { f.delegate.completions.count == 1 }
        #expect(f.delegate.completions.first?.1 == false && f.delegate.disconnected.isEmpty)
        await f.output.release()
        try await eventually { await f.output.response(42) != nil }
        try f.request(43, "ping")
        try await eventually { await f.output.response(43) != nil }
        f.input.finish(); try await f.task.value
        #expect(f.delegate.completions.count == 1) // Late receipt cannot commit an expired result.
    }

}
