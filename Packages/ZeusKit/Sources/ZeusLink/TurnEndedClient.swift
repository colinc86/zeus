import Foundation
import ZeusProtocol

/// Bounded one-shot hook transport. It never sends hello or evicts a live bridge.
public enum TurnEndedClient {
    /// Sends exactly one event and awaits a receipt within the supplied deadline.
    public static func send(_ event: TurnEnded, socketPath: String, timeout: Duration = .seconds(1)) async throws {
        let channel = try await SocketChannel.connect(path: socketPath)
        defer { channel.close() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await channel.send(.turnEnded(event))
                for try await message in channel.messages {
                    guard case .turnEndedReceipt = message else { throw BridgeLinkError.protocolViolation("Hook receipt missing") }
                    return
                }
                throw BridgeLinkError.disconnected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BridgeLinkError.timeout
            }
            defer { group.cancelAll(); channel.close() }
            _ = try await group.next()
        }
    }
}
