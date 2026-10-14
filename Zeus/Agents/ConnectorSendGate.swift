import Foundation

/// Serializes a paste+submit transaction for one destination while allowing other
/// destinations to proceed. Waiting sends honor cancellation without leaking a permit.
@MainActor
final class ConnectorSendGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var occupied: Set<String> = []
    private var waiting: [String: [Waiter]] = [:]

    func acquire(_ key: String) async throws {
        try Task.checkCancellation()
        if occupied.insert(key).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[key, default: []].append(.init(id: id, continuation: continuation))
                if Task.isCancelled { cancel(id: id, key: key) }
            }
        } onCancel: { Task { @MainActor in self.cancel(id: id, key: key) } }
        // Cancellation can race a permit handoff. Return an already-granted permit
        // before throwing, so the next delivery is not stranded behind this task.
        if Task.isCancelled { release(key); throw CancellationError() }
    }
    func release(_ key: String) {
        if var queue = waiting[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty { waiting.removeValue(forKey: key) } else { waiting[key] = queue }
            next.continuation.resume()
        } else { occupied.remove(key) }
    }
    private func cancel(id: UUID, key: String) {
        guard var queue = waiting[key], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let cancelled = queue.remove(at: index)
        if queue.isEmpty { waiting.removeValue(forKey: key) } else { waiting[key] = queue }
        cancelled.continuation.resume(throwing: CancellationError())
    }
}
