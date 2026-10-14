import Foundation
import ZeusProtocol

/// A connected bridge. Push receipts confirm stdout writes, never model acknowledgments.
public final class BridgeSession: Identifiable, Sendable {
    /// Per-process bridge UUID from hello.
    public let id: UUID
    /// Original bridge handshake metadata.
    public let hello: BridgeHello
    /// Agent-process identity computed from agent, cwd, parent PID and parent start time.
    public let sessionKey: String
    private let channel: SocketChannel
    private let receipts: PushReceipts

    internal init(hello: BridgeHello, channel: SocketChannel) {
        self.id = hello.bridgeID; self.hello = hello; self.sessionKey = hello.sessionKey
        self.channel = channel
        receipts = PushReceipts(channel: channel)
    }
    /// Resolves on pushWritten; throws on disconnect, cancellation or timeout (5 seconds).
    public func push(_ push: AgentPush) async throws { try await receipts.push(push) }
    /// Announces a learning; unread state is committed only by the polling tool's result receipt.
    public func notifyLearning(_ learning: BridgeLearning) async throws { try await channel.send(.learning(learning)) }
    internal func written(_ id: String) async { await receipts.written(id) }
    internal func supersede() async {
        try? await channel.send(.superseded(.init(sessionKey: sessionKey)))
        disconnect()
    }
    internal func disconnect() {
        channel.close()
        Task { await receipts.disconnect() }
    }
}

private actor PushReceipts {
    let channel: SocketChannel
    var connected = true
    struct Pending {
        let continuation: CheckedContinuation<Void, any Error>
        let timer: Task<Void, Never>
    }
    var pending: [String: Pending] = [:]
    init(channel: SocketChannel) { self.channel = channel }

    func push(_ push: AgentPush) async throws {
        try Task.checkCancellation()
        guard connected else { throw BridgeLinkError.disconnected }
        guard pending[push.deliveryID] == nil else { throw BridgeLinkError.protocolViolation("Push ID is already in flight") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    complete(push.deliveryID, error: BridgeLinkError.timeout)
                }
                pending[push.deliveryID] = Pending(continuation: continuation, timer: timer)
                Task {
                    do { try await channel.send(.push(push)) }
                    catch { complete(push.deliveryID, error: error) }
                }
            }
        } onCancel: { Task { await self.complete(push.deliveryID, error: CancellationError()) } }
    }
    func written(_ id: String) { complete(id, error: nil) }
    func complete(_ id: String, error: (any Error)?) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        if let error { request.continuation.resume(throwing: error) } else { request.continuation.resume() }
    }
    func disconnect() {
        connected = false
        channel.close()
        for id in Array(pending.keys) { complete(id, error: BridgeLinkError.disconnected) }
    }
}
