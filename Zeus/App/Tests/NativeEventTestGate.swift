import Foundation

/// Shares the app's one event queue across suites for tests that post real mouse events.
/// AppKit's mouse tracking takes the next mouse-up whatever its window, so two interleaved
/// presses could steal each other's release. Waiting suspends; it never blocks the main actor.
@MainActor enum NativeEventTestGate {
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
