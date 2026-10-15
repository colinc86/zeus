import Foundation

/// Shares one real-process fixture slot across suites. Waiting suspends; it never
/// occupies a dispatch worker or blocks the main actor. Tests release in defer,
/// after their private subprocess/socket cleanup. Fake-host unit tests do not use it.
@MainActor enum NativeProcessTestGate {
    private static var held = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    static func release() {
        precondition(held)
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().resume() }
    }
}
