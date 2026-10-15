import Foundation

/// Opaque window identity only: typing never requires a document title, URL or selected text.
struct TypingContext: Equatable, Sendable {
    var bundleID: String
    var appName: String
    var windowID: UInt32
    var processID: Int32
    var isPrivate = false
    var isLocked = false
    var secureInput = false
}
struct TypingPolicy: Equatable, Sendable {
    var enabled = false
    var consented = false
    /// Always an allow list. Empty means nothing is recorded; the private list wins.
    var apps: Set<String> = []
    var privateApps: Set<String> = []
    var words: TypingWordsRetention = .day
    /// PM task choice: 7/30/90 days, default 30 (the earlier design draft fixed topics at 30).
    var topicRetentionDays = 30
    /// Low Power Mode or battery under 30%: stage-one results stay in bounded RAM for at most ten minutes.
    var deferProcessing = false
    func permits(_ context: TypingContext) -> Bool {
        apps.contains(context.bundleID) && !privateApps.contains(context.bundleID)
    }
}
enum TypingPermission: String, Sendable { case notDetermined, denied, granted, revoked }
enum TypingPause: String, Sendable { case disabled, permission, modelUnavailable, privateContext, locked, secureInput }
/// Concrete observer uses Observation. There is deliberately no private-input thread notice or avatar alert.
@MainActor protocol TypingObserving: AnyObject {
    var permission: TypingPermission { get }
    var lastPermissionRequestGranted: Bool? { get }
    var permissionGrantedRequiresReopen: Bool { get }
    var privateInput: Bool { get }
    var isRecording: Bool { get }
    var pause: TypingPause? { get }
    var lastError: String? { get }
    func start()
    func stop()
    /// Explicit consent action only; start and timers never request Input Monitoring permission.
    @discardableResult func requestPermission() -> TypingPermission
    /// Call on app/window, lock, private-window, policy and wake events.
    func contextDidChange()
    /// Call before forgetting journal content, so suspended processing cannot repopulate it.
    func invalidatePendingCapture()
}
extension TypingObserving {
    var permissionGrantedRequiresReopen: Bool { lastPermissionRequestGranted == true && permission != .granted }
}
