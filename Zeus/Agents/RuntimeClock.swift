import Foundation

/// Wall-clock deadlines used by ask windows and persisted redelivery timestamps.
@MainActor
protocol RuntimeClock {
    /// Current time, shared by all runtime decisions.
    var now: Date { get }
    /// Suspends until the deadline. Implementations must honor task cancellation.
    func sleep(until deadline: Date) async throws
}

/// Production clock; tests supply a clock that advances without real waiting.
@MainActor
struct SystemRuntimeClock: RuntimeClock {
    var now: Date { Date() }
    func sleep(until deadline: Date) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now))))
    }
}
