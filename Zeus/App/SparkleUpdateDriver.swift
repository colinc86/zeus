import Foundation
import Sparkle

/// Keeps Sparkle and its KVO callbacks behind the app's update seam. No request headers or credentials.
@MainActor final class SparkleUpdateDriver: NSObject, UpdateDriving, SPUStandardUserDriverDelegate {
    var onChange: (() -> Void)?
    var onPendingUpdate: ((Bool) -> Void)?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    private var observations: [NSKeyValueObservation] = []
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() throws {
        // The throwing API lets our Settings show startup failures without a modal configuration alert.
        try controller.updater.start()
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        ]
    }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Zeus is a background app. Even a check near launch must never steal focus.
        false
    }
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Sparkle's standard UI invokes its Objective-C delegate on the main thread.
        MainActor.assumeIsolated {
            if !state.userInitiated && !handleShowingUpdate { onPendingUpdate?(true) }
        }
    }
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { onPendingUpdate?(false) }
    }
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { onPendingUpdate?(false) }
    }
}
