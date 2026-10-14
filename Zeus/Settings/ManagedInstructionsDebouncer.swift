import Foundation

/// Coalesces instruction edits; leaving the editor flushes the latest edit once.
@MainActor final class ManagedInstructionsDebouncer {
    private var task: Task<Void, Never>?
    private var pending: (() -> Void)?
    private var generation = UUID()
    private let wait: @MainActor () async throws -> Void

    init(wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(800)) }) {
        self.wait = wait
    }
    func schedule(_ action: @escaping () -> Void) {
        cancel()
        pending = action
        let token = generation, wait = wait
        task = Task { [weak self] in
            do { try await wait() } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.flush()
        }
    }
    func flush() {
        let action = pending
        cancel()
        action?()
    }
    func cancel() {
        task?.cancel(); task = nil; pending = nil; generation = UUID()
    }
    deinit { task?.cancel() }
}
