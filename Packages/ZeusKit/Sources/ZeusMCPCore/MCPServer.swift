import Foundation
import ZeusLink
import ZeusProtocol

/// Serialized MCP output. Implementations must write each complete frame atomically and
/// return only after it has been flushed to the underlying stream. Throw on output failure.
public protocol MCPOutput: Sendable {
    /// Writes one compact UTF-8 JSON-RPC message with its terminating newline.
    func writeAndFlush(_ frame: Data) async throws
}

/// Testable stdio JSON-RPC server. Models and tool definitions are served without the app.
///
/// Feed raw stdin chunks into run; EOF stops retries and resolves in-flight tool calls.
/// An app connection is attempted after initialize, then retried in the background.
/// Request IDs are preserved and slow tools do not block ping, listing, or channel pushes.
public actor MCPServer {
    private let configuration: MCPConfiguration
    private let bridge: BridgeClient
    private var output: (any MCPOutput)?
    private var log: (@Sendable (String) -> Void)?
    private var running = false
    private var hasRun = false
    private var hello: BridgeHello?
    private var initialized = false
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var firstAttempt: Task<Bool, Never>?
    private var connector: Task<Void, Never>?
    private var connectionAttempt: Task<Bool, Never>?
    private var clientStarted = false
    private var lastConnectionError: String?
    private struct Request {
        let token: UUID
        let task: Task<Void, Never>
        var responding = false
    }
    private var requests: [RPCID: Request] = [:]
    private enum Event: Sendable { case chunk(Data), eof, failure(any Error) }
    private var events: AsyncStream<Event>.Continuation?

    /// Creates a single-use server. Metadata is captured here, before MCP initialization.
    public init(configuration: MCPConfiguration = .init()) {
        self.configuration = configuration
        bridge = BridgeClient(socketPath: configuration.socketPath)
    }

    /// Runs until stdin EOF, cancellation or an I/O failure. Logging is always separate from output.
    /// The input stream must honor cancellation; AsyncThrowingStream does so by default.
    public func run(input: AsyncThrowingStream<Data, any Error>, output: any MCPOutput,
                    log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard !hasRun else { throw MCPServerError.alreadyRun }
        hasRun = true; running = true; self.output = output; self.log = log
        defer { events = nil; self.output = nil; self.log = nil }
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        events = continuation
        let inputTask = Task {
            do {
                for try await chunk in input { continuation.yield(.chunk(chunk)) }
                continuation.yield(.eof)
            } catch { continuation.yield(.failure(error)) }
        }
        var framer = StdioFramer(limit: configuration.maximumFrameBytes)
        do {
            eventLoop: for await event in stream {
                try Task.checkCancellation()
                switch event {
                case .chunk(let chunk):
                    for frame in framer.append(chunk) {
                        switch frame {
                        case .data(let data): try await receive(data)
                        case .oversized: try await write(JSONRPC.error(code: -32700, message: "JSON frame exceeds byte limit"))
                        }
                    }
                case .eof:
                    if framer.hasIncompleteFrame { try await write(JSONRPC.error(code: -32700, message: "Unterminated JSON frame at EOF")) }
                    break eventLoop
                case .failure(let error): throw error
                }
            }
            inputTask.cancel(); continuation.finish()
            await shutdown(respond: true)
        } catch {
            inputTask.cancel(); continuation.finish()
            await shutdown(respond: false)
            throw error
        }
    }

    private func receive(_ data: Data) async throws {
        let json: JSONValue
        do {
            guard String(data: data, encoding: .utf8) != nil else { throw MCPServerError.invalidUTF8 }
            json = try ZeusJSON.decoder().decode(JSONValue.self, from: data)
        } catch { try await write(JSONRPC.error(code: -32700, message: "Parse error")); return }
        guard case .object = json, json["jsonrpc"] == "2.0" else {
            try await write(JSONRPC.error(code: -32600, message: "Invalid Request")); return
        }
        let id = json["id"].flatMap(RPCID.init)
        // Responses to server-originated requests are irrelevant: Zeus only sends notifications.
        if json["method"] == nil, id != nil, json["result"] != nil || json["error"] != nil { return }
        guard case .string(let method) = json["method"], json["id"] == nil || id != nil else {
            try await write(JSONRPC.error(code: -32600, message: "Invalid Request")); return
        }
        guard let id else {
            if method == "notifications/initialized", hello != nil {
                initialized = true
                let waiters = readyWaiters; readyWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: true) }
            }
            // Valid notifications, including unknown notifications, never get a response.
            return
        }
        switch method {
        case "initialize":
            guard hello == nil else { try await write(JSONRPC.error(id: id, code: -32600, message: "Already initialized")); return }
            guard case .object = json["params"], case .string = json["params"]?["protocolVersion"],
                  case .object = json["params"]?["capabilities"],
                  case .string(let name) = json["params"]?["clientInfo"]?["name"],
                  case .string(let version) = json["params"]?["clientInfo"]?["version"] else {
                try await write(JSONRPC.error(id: id, code: -32602, message: "Invalid initialize params")); return
            }
            let greeting = configuration.hello(client: .init(name: name, version: version))
            hello = greeting
            try await write(JSONRPC.result(id: id, ["protocolVersion": .string(ZeusMCP.protocolVersion),
                "capabilities": ZeusMCP.capabilities(agent: configuration.agent),
                "serverInfo": ["name": "zeus", "version": .string(configuration.version)],
                "instructions": .string(ZeusMCP.instructions)]))
            connect(greeting)
        case "ping": try await write(JSONRPC.result(id: id, [:]))
        case "tools/list": try await write(JSONRPC.result(id: id, ["tools": try .from(ZeusMCP.tools)]))
        case "tools/call":
            guard hello != nil else { try await write(JSONRPC.error(id: id, code: -32000, message: "Server is not initialized")); return }
            guard case .string(let name) = json["params"]?["name"], ZeusMCP.tools.contains(where: { $0.name == name }) else {
                try await write(JSONRPC.error(id: id, code: -32602, message: "Unknown or missing tool name")); return
            }
            let arguments = json["params"]?["arguments"] ?? [:]
            guard case .object = arguments else { try await write(JSONRPC.error(id: id, code: -32602, message: "Tool arguments must be an object")); return }
            guard requests[id] == nil else { try await write(JSONRPC.error(id: id, code: -32600, message: "Request ID already in flight")); return }
            let token = UUID()
            let task = Task {
                let result: ToolResult
                var receiptID: String?
                do {
                    if await bridge.welcome == nil, let hello { _ = await attemptConnection(hello) }
                    try Task.checkCancellation()
                    let response = try await bridge.requestTool(name: name, arguments: arguments)
                    result = response.result; receiptID = response.callID
                } catch {
                    result = ToolResult(text: ZeusMCP.appNotRunningText, isError: true)
                }
                await complete(id: id, token: token, result: result, receiptID: receiptID)
            }
            requests[id] = Request(token: token, task: task)
        default: try await write(JSONRPC.error(id: id, code: -32601, message: "Method not found"))
        }
    }

    private func connect(_ greeting: BridgeHello) {
        let attempt = Task { await attemptConnection(greeting) }
        firstAttempt = attempt
        connector = Task {
            guard !(await attempt.value) else { return } // BridgeClient owns live-session reconnects.
            var delay = 0.25
            while running, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard running, !Task.isCancelled else { return }
                if await attemptConnection(greeting) { return }
                delay = min(delay * 2, 5)
            }
        }
    }
    private func attemptConnection(_ greeting: BridgeHello) async -> Bool {
        guard running, !Task.isCancelled else { return false }
        if let connectionAttempt { return await connectionAttempt.value }
        let task = Task { await performConnection(greeting) }
        connectionAttempt = task
        defer { connectionAttempt = nil }
        return await task.value
    }

    private func performConnection(_ greeting: BridgeHello) async -> Bool {
        do {
            if clientStarted { _ = try await bridge.reconnectNow() }
            else {
                _ = try await bridge.start(hello: greeting, onPush: { [weak self] push in await self?.forward(push) },
                    onLearning: { [weak self] learning in await self?.forwardLearning(learning) })
                clientStarted = true
            }
            lastConnectionError = nil
            return true
        } catch {
            let message = error.localizedDescription
            if message != lastConnectionError {
                log?("zeus-mcp: socket \(configuration.socketPath): \(message)")
                lastConnectionError = message
            }
            return false
        }
    }

    private func forwardLearning(_ learning: BridgeLearning) async {
        guard running, configuration.agent == .claude else { return }
        if !initialized {
            let ready = await withCheckedContinuation { readyWaiters.append($0) }
            guard ready, running else { return }
        }
        do { try await write(JSONRPC.learning(learning)) }
        catch { events?.yield(.failure(error)) }
    }
    private func forward(_ push: AgentPush) async {
        guard running, configuration.agent == .claude else { return }
        if !initialized {
            let ready = await withCheckedContinuation { readyWaiters.append($0) }
            guard ready, running else { return }
        }
        do { try await write(JSONRPC.channel(push)) }
        catch { events?.yield(.failure(error)); return }
        do { try await bridge.reportPushWritten(deliveryID: push.deliveryID) }
        catch { log?("zeus-mcp: channel was written, but the socket receipt could not be sent") }
    }
    private func complete(id: RPCID, token: UUID, result: ToolResult, receiptID: String?) async {
        guard running, requests[id]?.token == token else { return }
        // Mark the response committed before suspending, so EOF never emits a second result.
        requests[id]?.responding = true
        do {
            try await write(JSONRPC.result(id: id, JSONRPC.toolResult(result)))
            if let receiptID {
                do { try await bridge.reportToolResultWritten(callID: receiptID) }
                catch { log?("zeus-mcp: tool result was written, but its socket receipt could not be sent") }
            }
        }
        catch { events?.yield(.failure(error)) }
        if requests[id]?.token == token { requests.removeValue(forKey: id) }
    }
    private func write(_ json: JSONValue) async throws {
        guard let output else { throw MCPServerError.closed }
        var frame = try ZeusJSON.encoder().encode(json)
        frame.append(10)
        try await output.writeAndFlush(frame)
    }
    private func shutdown(respond: Bool) async {
        running = false
        let waiters = readyWaiters; readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
        let pending = requests; requests.removeAll()
        for request in pending.values where !request.responding { request.task.cancel() }
        firstAttempt?.cancel(); connector?.cancel()
        connectionAttempt?.cancel()
        await bridge.stop()
        if respond {
            for (id, request) in pending where !request.responding {
                try? await write(JSONRPC.result(id: id, JSONRPC.toolResult(.init(text: "Zeus bridge stopped before the tool completed.", isError: true))))
            }
        }
        for request in pending.values { await request.task.value }
        _ = await firstAttempt?.value
        await connector?.value
        _ = await connectionAttempt?.value
        connectionAttempt = nil
        firstAttempt = nil; connector = nil
    }
}

/// Lifecycle and framing failures from MCPServer.
public enum MCPServerError: Error, Sendable, LocalizedError {
    case alreadyRun, invalidUTF8, closed
    public var errorDescription: String? {
        switch self {
        case .alreadyRun: "MCPServer can only be run once"
        case .invalidUTF8: "stdin frame is not UTF-8"
        case .closed: "MCP output is closed"
        }
    }
}
