import Foundation
import Synchronization
import ZeusProtocol

/// App-side events. Delegate calls and session ordering are confined to the MainActor.
@MainActor public protocol BridgeServerDelegate: AnyObject {
    /// A valid hello was accepted and its welcome was sent.
    func bridgeDidConnect(_ session: BridgeSession)
    /// A connected session closed, failed, stopped or was superseded by a newer bridge.
    func bridgeDidDisconnect(_ session: BridgeSession)
    /// Handles one forwarded tool request. Requests may execute concurrently.
    func bridge(_ session: BridgeSession, callTool name: String, arguments: JSONValue) async -> ToolResult
    /// Result completion at stdout (capable bridges), or socket output (legacy bridges).
    /// Failure means no consumption was committed and durable input must remain pending.
    func bridge(_ session: BridgeSession, finishedTool name: String, result: ToolResult, written: Bool)
    /// A launch-only native hook; this connection has no hello/session or delivery privileges.
    func bridgeTurnEnded(_ event: TurnEnded) async
}

public extension BridgeServerDelegate {
    /// Optional delivery-commit callback for existing delegates.
    func bridge(_ session: BridgeSession, finishedTool name: String, result: ToolResult, written: Bool) {}
    func bridgeTurnEnded(_ event: TurnEnded) async {}
}

/// Unix-socket listener used by Zeus.app. start throws synchronously for bind failures.
///
/// Create ZeusPaths directories before starting at the standard path. Retain both the
/// server and delegate for the application's lifetime; the delegate is held weakly.
/// Delegate callbacks run on the MainActor. Long-running tool handlers suspend without
/// blocking pushWritten receipts or other tool requests.
public final class BridgeServer: Sendable {
    private let socketPath: String
    private let resultReceiptTimeout: Duration
    private struct Lifecycle {
        var listener: ListeningSocket?
        var state: ServerState?
    }
    private let lifecycle = Mutex(Lifecycle())
    /// Creates a listener at a custom path or ZeusPaths.bridgeSocket.path.
    /// Unconfirmed results expire after five seconds by default. This releases
    /// canceled/dropped tool replies without waiting for a session disconnect.
    public init(socketPath: String, resultReceiptTimeout: Duration = .seconds(5)) {
        self.socketPath = socketPath; self.resultReceiptTimeout = resultReceiptTimeout
    }

    /// Starts listening with mode 0600. A newer hello with the same sessionKey replaces the old session.
    @MainActor public func start(delegate: any BridgeServerDelegate) throws {
        let (socket, newState) = try lifecycle.withLock { value in
            guard value.state == nil else { throw BridgeLinkError.protocolViolation("Server already started") }
            let socket = try ListeningSocket(path: socketPath)
            let state = ServerState(delegate: delegate, receiptTimeout: resultReceiptTimeout)
            value = Lifecycle(listener: socket, state: state)
            return (socket, state)
        }
        socket.run { channel in Task { @MainActor in newState.accept(channel) } }
    }
    /// Stops accepting immediately, then closes sessions and reports disconnects on the MainActor.
    public func stop() {
        let old = lifecycle.withLock { value in
            value.listener?.stop()
            let state = value.state
            value = Lifecycle()
            return state
        }
        Task { @MainActor in old?.stop() }
    }
    deinit {
        let old = lifecycle.withLock { value in value.listener?.stop(); return value.state }
        Task { @MainActor in old?.stop() }
    }
}

@MainActor private final class ServerState {
    weak var delegate: (any BridgeServerDelegate)?
    var stopped = false
    var channels: [UUID: SocketChannel] = [:]
    var sessions: [String: BridgeSession] = [:]
    var latestHello: [String: UUID] = [:]
    let receiptTimeout: Duration
    struct AwaitedResult { let session: BridgeSession; let name: String; let result: ToolResult; let timer: Task<Void, Never> }
    var awaitedResults: [UUID: [String: AwaitedResult]] = [:]
    init(delegate: any BridgeServerDelegate, receiptTimeout: Duration) { self.delegate = delegate; self.receiptTimeout = receiptTimeout }
    func finishResult(token: UUID, callID: String, written: Bool) {
        guard let pending = awaitedResults[token]?.removeValue(forKey: callID) else { return }
        pending.timer.cancel()
        delegate?.bridge(pending.session, finishedTool: pending.name, result: pending.result, written: written)
    }

    func accept(_ channel: SocketChannel) {
        guard !stopped else { channel.close(); return }
        let token = UUID()
        channels[token] = channel
        Task { [self] in
            var session: BridgeSession?
            var handshakeKey: String?
            let handshakeTimeout = Task {
                do { try await Task.sleep(for: .seconds(5)); channel.close() } catch { }
            }
            defer { handshakeTimeout.cancel() }
            do {
                messageLoop: for try await message in channel.messages {
                    if session == nil {
                        if case .turnEnded(let event) = message {
                            guard event.wireVersion == wireVersion else { throw BridgeLinkError.protocolViolation("Unsupported hook wireVersion") }
                            handshakeTimeout.cancel()
                            await delegate?.bridgeTurnEnded(event)
                            try await channel.send(.turnEndedReceipt(.init()))
                            break messageLoop
                        }
                        guard case .hello(let hello) = message else { throw BridgeLinkError.protocolViolation("First message must be hello") }
                        guard hello.wireVersion == wireVersion else { throw BridgeLinkError.protocolViolation("Unsupported wireVersion \(hello.wireVersion); expected \(wireVersion)") }
                        guard hello.ppid > 0, hello.parentStartTime > 0 else {
                            throw BridgeLinkError.protocolViolation("Missing agent process identity; restart the agent's zeus-mcp with the updated bridge.")
                        }
                        handshakeTimeout.cancel()
                        handshakeKey = hello.sessionKey
                        latestHello[hello.sessionKey] = token
                        let connected = BridgeSession(hello: hello, channel: channel)
                        try await channel.send(.welcome(.init(sessionKey: connected.sessionKey, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0", toolResultWritten: hello.capabilities.toolResultWritten)))
                        // A write suspends. Only the newest valid hello may claim the routing key.
                        guard !stopped, latestHello[hello.sessionKey] == token else { connected.disconnect(); break }
                        if let old = sessions[connected.sessionKey] {
                            if old.id == connected.id {
                                // Replacing a transport for the same bridge isn't agent eviction.
                                old.disconnect()
                            } else {
                                await old.supersede()
                            }
                            guard !stopped, latestHello[hello.sessionKey] == token else { connected.disconnect(); break }
                            if sessions[connected.sessionKey] === old {
                                sessions.removeValue(forKey: connected.sessionKey)
                                if old.id != connected.id { delegate?.bridgeDidDisconnect(old) }
                            }
                        }
                        sessions[connected.sessionKey] = connected
                        session = connected
                        delegate?.bridgeDidConnect(connected)
                    } else if let connected = session {
                        guard sessions[connected.sessionKey] === connected else { break }
                        switch message {
                        case .toolCall(let call):
                            Task {
                                guard sessions[connected.sessionKey] === connected, let delegate else { return }
                                let result = await delegate.bridge(connected, callTool: call.name, arguments: call.arguments)
                                guard sessions[connected.sessionKey] === connected else {
                                    delegate.bridge(connected, finishedTool: call.name, result: result, written: false); return
                                }
                                if connected.hello.capabilities.toolResultWritten {
                                    let timer = Task { [weak self, receiptTimeout] in
                                        do { try await Task.sleep(for: receiptTimeout) } catch { return }
                                        self?.finishResult(token: token, callID: call.callID, written: false)
                                    }
                                    awaitedResults[token, default: [:]][call.callID] = .init(session: connected, name: call.name, result: result, timer: timer)
                                }
                                do {
                                    try await channel.send(.toolResult(.init(callID: call.callID, result: result)))
                                    if !connected.hello.capabilities.toolResultWritten {
                                        delegate.bridge(connected, finishedTool: call.name, result: result, written: true)
                                    }
                                } catch {
                                    if connected.hello.capabilities.toolResultWritten {
                                        finishResult(token: token, callID: call.callID, written: false)
                                    } else { delegate.bridge(connected, finishedTool: call.name, result: result, written: false) }
                                    channel.close()
                                }
                            }
                        case .pushWritten(let receipt): await connected.written(receipt.deliveryID)
                        case .toolResultWritten(let receipt):
                            finishResult(token: token, callID: receipt.callID, written: true)
                        case .error: break messageLoop
                        default: throw BridgeLinkError.protocolViolation("Unexpected bridge-to-app message")
                        }
                    }
                }
            } catch {
                try? await channel.send(.error(.init(message: error.localizedDescription)))
            }
            channel.close()
            for pending in awaitedResults.removeValue(forKey: token)?.values ?? [:].values {
                pending.timer.cancel()
                delegate?.bridge(pending.session, finishedTool: pending.name, result: pending.result, written: false)
            }
            channels.removeValue(forKey: token)
            if let key = handshakeKey, latestHello[key] == token { latestHello.removeValue(forKey: key) }
            if let session {
                session.disconnect()
                if sessions[session.sessionKey] === session {
                    sessions.removeValue(forKey: session.sessionKey)
                    delegate?.bridgeDidDisconnect(session)
                }
            }
        }
    }

    func stop() {
        stopped = true
        for channel in channels.values { channel.close() }
        let old = Array(sessions.values)
        sessions.removeAll()
        for session in old { session.disconnect(); delegate?.bridgeDidDisconnect(session) }
    }
}
