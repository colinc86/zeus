import Foundation
import ZeusProtocol

/// Bridge-side socket client. Reconnects with 0.25→0.5→1…5 second backoff after a live connection drops.
/// Explicit supersession retires automatic retries until reconnectNow is called for a new tool request.
/// Tool calls are not replayed: a disconnected call fails so the MCP layer can report an error safely.
///
/// Retain the client while the stdio bridge is running and call stop before exit. The
/// initial start failure lets tools/call report ZeusMCP.appNotRunningText. Call start
/// again on a subsequent tool request to retry that initial failure. Once welcomed,
/// socket reconnects are automatic and reuse the supplied per-process bridgeID.
/// onPush/onLearning callbacks run serially in wire order; keep them short and do not wait for
/// another tool result inside them. Explicitly reportPushWritten after writing stdout.
public final class BridgeClient: Sendable {
    private let state: ClientState
    /// Creates a client; no I/O happens until start.
    public init(socketPath: String) { state = ClientState(socketPath: socketPath) }

    /// Connects and performs hello/welcome. Initial failure is thrown; ordinary disconnects retry automatically.
    /// onPush must write the notification to stdout before calling reportPushWritten; receipt is never automatic.
    public func start(hello: BridgeHello,
                      onPush: @escaping @Sendable (AgentPush) async -> Void,
                      onLearning: @escaping @Sendable (BridgeLearning) async -> Void = { _ in },
                      onDisconnect: @escaping @Sendable () async -> Void = {}) async throws -> BridgeWelcome {
        try await state.start(hello: hello, onPush: onPush, onDisconnect: onDisconnect, onLearning: onLearning)
    }
    /// Latest welcome, or nil while disconnected/reconnecting.
    public var welcome: BridgeWelcome? { get async { await state.welcome } }
    /// An explicit tool request may bypass backoff or wake a superseded bridge.
    /// Shares a handshake already in flight; never replays previously written tools.
    public func reconnectNow() async throws -> BridgeWelcome { try await state.reconnectNow() }
    /// Forwards a tool request. Default timeout accommodates the maximum 600-second ask window.
    public func callTool(name: String, arguments: JSONValue = [:], timeout: Duration = .seconds(610)) async throws -> ToolResult {
        let response = try await requestTool(name: name, arguments: arguments, timeout: timeout)
        try await reportToolResultWritten(callID: response.callID)
        return response.result
    }
    /// Returns correlation data without committing result consumption. MCP callers must
    /// reportToolResultWritten only after their output frame has been flushed.
    public func requestTool(name: String, arguments: JSONValue = [:], timeout: Duration = .seconds(610)) async throws -> BridgeToolResult {
        try await state.callTool(name: name, arguments: arguments, timeout: timeout)
    }
    /// Commits a correlated result; no-op for bridges without the receipt capability.
    public func reportToolResultWritten(callID: String) async throws { try await state.reportToolResultWritten(callID) }
    /// Reports successful stdout notification output. Does not acknowledge model receipt.
    public func reportPushWritten(deliveryID: String) async throws { try await state.reportPushWritten(deliveryID) }
    /// Cancels reconnects, closes the socket, and fails pending calls. The client may then be started again.
    public func stop() async { await state.stop() }
}

private actor ClientState {
    let socketPath: String
    var hello: BridgeHello?
    var welcome: BridgeWelcome?
    var onPush: (@Sendable (AgentPush) async -> Void)?
    var onDisconnect: (@Sendable () async -> Void)?
    var onLearning: (@Sendable (BridgeLearning) async -> Void)?
    var channel: SocketChannel?
    var reader: Task<Void, Never>?
    var reconnect: Task<Void, Never>?
    var establishment: Task<BridgeWelcome, any Error>?
    var establishmentID: UUID?
    var superseded = false
    var generation = UUID()
    struct Pending {
        let continuation: CheckedContinuation<BridgeToolResult, any Error>
        let timer: Task<Void, Never>
    }
    var pending: [String: Pending] = [:]

    init(socketPath: String) { self.socketPath = socketPath }
    func start(hello: BridgeHello, onPush: @escaping @Sendable (AgentPush) async -> Void,
               onDisconnect: @escaping @Sendable () async -> Void,
               onLearning: @escaping @Sendable (BridgeLearning) async -> Void) async throws -> BridgeWelcome {
        guard self.hello == nil else { throw BridgeLinkError.protocolViolation("Client already started") }
        self.hello = hello; self.onPush = onPush; self.onDisconnect = onDisconnect
        self.onLearning = onLearning
        let token = generation
        superseded = false
        do { return try await connectOnce(token: token) }
        catch {
            if token == generation { await stop() }
            throw error
        }
    }

    func connectOnce(token: UUID) async throws -> BridgeWelcome {
        if let welcome { return welcome }
        if let establishment { return try await establishment.value }
        let id = UUID()
        let task = Task { try await establish(token: token) }
        establishment = task; establishmentID = id
        defer { if establishmentID == id { establishment = nil; establishmentID = nil } }
        return try await task.value
    }

    func reconnectNow() async throws -> BridgeWelcome {
        try Task.checkCancellation()
        guard hello != nil else { throw BridgeLinkError.stopped }
        if let welcome { return welcome }
        reconnect?.cancel(); reconnect = nil
        superseded = false
        do { return try await connectOnce(token: generation) }
        catch { scheduleReconnect(token: generation); throw error }
    }

    func establish(token: UUID) async throws -> BridgeWelcome {
        guard let hello, token == generation else { throw BridgeLinkError.stopped }
        let connected = try await SocketChannel.connect(path: socketPath)
        guard token == generation else { connected.close(); throw BridgeLinkError.stopped }
        channel = connected
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)); connected.close() } catch { }
        }
        defer { deadline.cancel() }
        do {
            try await connected.send(.hello(hello))
            var iterator = connected.messages.makeAsyncIterator()
            guard let first = try await iterator.next() else { throw BridgeLinkError.disconnected }
            guard case .welcome(let response) = first else {
                if case .error(let error) = first { throw BridgeLinkError.protocolViolation(error.message) }
                throw BridgeLinkError.protocolViolation("First app message must be welcome")
            }
            guard response.wireVersion == wireVersion, response.sessionKey == hello.sessionKey else {
                throw BridgeLinkError.protocolViolation("Invalid welcome version or sessionKey")
            }
            guard token == generation else { throw BridgeLinkError.stopped }
            welcome = response
            reader = Task { await consume(connected, token: token) }
            return response
        } catch {
            connected.close()
            if channel === connected { channel = nil; welcome = nil }
            throw error
        }
    }

    func consume(_ connected: SocketChannel, token: UUID) async {
        do {
            messageLoop: for try await message in connected.messages {
                guard token == generation, channel === connected else { break }
                switch message {
                case .toolResult(let result): finish(result.callID, result: result, error: nil)
                case .push(let push): await onPush?(push)
                case .learning(let learning): await onLearning?(learning)
                case .error(let error): throw BridgeLinkError.protocolViolation(error.message)
                case .superseded(let notice):
                    guard notice.sessionKey == hello?.sessionKey else { throw BridgeLinkError.protocolViolation("Invalid superseded sessionKey") }
                    superseded = true
                    reconnect?.cancel(); reconnect = nil
                    break messageLoop
                default: throw BridgeLinkError.protocolViolation("Unexpected app-to-bridge message")
                }
            }
        } catch { /* Pending requests fail below; reconnect never replays tool calls. */ }
        connected.close()
        guard token == generation, channel === connected else { return }
        channel = nil; welcome = nil
        failAll(BridgeLinkError.disconnected)
        await onDisconnect?()
        guard token == generation else { return }
        scheduleReconnect(token: token)
    }

    func scheduleReconnect(token: UUID) {
        guard !superseded, hello != nil, token == generation, reconnect == nil else { return }
        reconnect = Task {
            var delay = 0.25
            while !Task.isCancelled, token == generation {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                do { _ = try await connectOnce(token: token); reconnect = nil; return }
                catch { delay = min(delay * 2, 5) }
            }
        }
    }

    func callTool(name: String, arguments: JSONValue, timeout: Duration) async throws -> BridgeToolResult {
        try Task.checkCancellation()
        guard let channel, welcome != nil else { throw BridgeLinkError.disconnected }
        let call = ToolCall(name: name, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    finish(call.callID, result: nil, error: BridgeLinkError.timeout)
                }
                pending[call.callID] = Pending(continuation: continuation, timer: timer)
                Task {
                    do { try await channel.send(.toolCall(call)) }
                    catch { finish(call.callID, result: nil, error: error) }
                }
            }
        } onCancel: { Task { await self.finish(call.callID, result: nil, error: CancellationError()) } }
    }
    func reportToolResultWritten(_ id: String) async throws {
        guard welcome?.toolResultWritten == true else { return }
        guard let channel, welcome != nil else { throw BridgeLinkError.disconnected }
        try await channel.send(.toolResultWritten(.init(callID: id)))
    }
    func reportPushWritten(_ id: String) async throws {
        guard let channel, welcome != nil else { throw BridgeLinkError.disconnected }
        try await channel.send(.pushWritten(.init(deliveryID: id)))
    }
    func finish(_ id: String, result: BridgeToolResult?, error: (any Error)?) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        if let result { request.continuation.resume(returning: result) }
        else { request.continuation.resume(throwing: error ?? BridgeLinkError.disconnected) }
    }
    func failAll(_ error: any Error) { for id in Array(pending.keys) { finish(id, result: nil, error: error) } }
    func stop() async {
        let wasConnected = welcome != nil
        generation = UUID()
        hello = nil; welcome = nil
        reconnect?.cancel(); reconnect = nil
        establishment?.cancel(); establishment = nil; establishmentID = nil
        superseded = false
        reader?.cancel(); reader = nil
        channel?.close(); channel = nil
        failAll(BridgeLinkError.stopped)
        let callback = onDisconnect
        onPush = nil; onDisconnect = nil; onLearning = nil
        if wasConnected { await callback?() }
    }
}
