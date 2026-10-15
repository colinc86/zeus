import Foundation

/// App supplies only permitted context. No capture is made while any stop is true, even for on-demand requests.
struct ScreenContext: Equatable, Sendable {
    var bundleID: String
    var appName: String
    var windowTitle: String
    var windowID: UInt32
    var processID: Int32
    var isPrivate = false
    var isLocked = false
    var secureInput = false
    var cameraInUse = false
    var isMirrored = false
    var isPresenting = false
}
struct ScreenPolicy: Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case everywhereExcept, onlyChosen }
    var enabled = false
    var consented = false
    var scope: Scope = .everywhereExcept
    var apps: Set<String> = []
    var privateApps: Set<String> = []
    var capturesPerHour = 12
    var descriptionRetentionDays = 90
    /// App sets this for Low Power Mode or battery below 30%; pictures still work.
    var deferDescriptions = false
    func permits(_ context: ScreenContext) -> Bool {
        !privateApps.contains(context.bundleID) && (scope == .onlyChosen ? apps.contains(context.bundleID) : !apps.contains(context.bundleID))
    }
}
enum BrowserWindowPrivacy: String, Sendable { case normal, `private`, unknown }
enum ScreenPermission: String, Sendable { case notDetermined, denied, granted, revoked }
enum ScreenPause: String, Sendable {
    case disabled, permission, privateContext, locked, secureInput, camera, presenting, sensitiveApp, cap
}
/// Presentation is observable on the concrete observer. Settings owns consent, app lists and macOS permission requests.
@MainActor protocol ScreenObserving: AnyObject {
    var permission: ScreenPermission { get }
    var lastPermissionRequestGranted: Bool? { get }
    var permissionGrantedRequiresReopen: Bool { get }
    var pause: ScreenPause? { get }
    var lastError: String? { get }
    func start()
    func stop()
    /// Call on app/document, lock, private-window, policy and idle-return events. Invalidates suspended captures immediately.
    func contextDidChange(returnedFromIdle: Bool)
    /// Explicit consent-button action only. Never requested by start/tick/capture.
    @discardableResult func requestPermission() -> ScreenPermission
    func captureNow()
    /// Local Ask About This only; no transmission. Nil means paused/changed/failed. Reuses a verified unchanged frame.
    func captureOnDemand() async -> ScreenCaptureResult?
    /// Call before journal deletion so an older suspended capture cannot restore deleted content.
    func invalidatePendingCapture()
}

/// Opaque routing identity for an owned front window. Display titles are present only in the redacted result.
struct ScreenCaptureIdentity: Codable, Equatable, Sendable {
    let bundleID: String
    let processID: Int32
    let windowID: UInt32
}
struct ScreenCaptureResult: Sendable {
    let identity: ScreenCaptureIdentity
    let time: Date
    let frameID: String?
    let descriptionID: String?
    let frame: Redacted<FrameItem>?
    let description: Redacted<JournalPayload>?
}

extension ScreenObserving {
    var lastPermissionRequestGranted: Bool? { nil }
    var permissionGrantedRequiresReopen: Bool { false }
}
