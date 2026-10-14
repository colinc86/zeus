import AppKit
import CoreGraphics
import Foundation

/// What the Mac reports, before any exclusion or pause.
enum ActivitySignal: Equatable, Sendable {
    case activated(bundleID: String?, name: String?)
    case launched(bundleID: String?, name: String?)
    case quit(bundleID: String?, name: String?)
    case locked, unlocked, sleep, wake
    case displays(Int)
}

/// Where the recorder's signals come from. The app uses `WorkspaceActivitySource`; tests use a fake and never observe
/// the real workspace.
@MainActor
protocol ActivityEventSource: AnyObject {
    func start(_ handler: @escaping @MainActor (ActivitySignal) -> Void)
    func stop()
    /// Seconds since the last keyboard or mouse input (a number, never the input itself).
    var secondsSinceLastInput: TimeInterval { get }
    /// The frontmost app when recording starts.
    var frontmostApp: (bundleID: String?, name: String?)? { get }
    var displayCount: Int { get }
}

/// Turns signals into raw events: excluded apps become private time with no name, idle periods come from a poll
/// (`tick`), and nothing is written while paused. Off until `start()`.
@MainActor
final class ActivityRecorder {
    static let idleThreshold: TimeInterval = 5 * 60
    private let source: any ActivityEventSource
    private let isExcluded: (String?, String?) -> Bool
    private let isPaused: (Date) -> Bool
    private let write: (ActivityEvent) -> Void
    private let clock: () -> Date
    private(set) var isRunning = false
    /// When the current idle period started (the last input), or nil.
    private(set) var idleSince: Date?
    private var current: (bundleID: String?, name: String?)?
    private var privateSince: Date?
    private var asleepOrLocked = false

    init(source: any ActivityEventSource, isExcluded: @escaping (String?, String?) -> Bool, isPaused: @escaping (Date) -> Bool,
         clock: @escaping () -> Date = Date.init, write: @escaping (ActivityEvent) -> Void) {
        self.source = source
        self.isExcluded = isExcluded
        self.isPaused = isPaused
        self.clock = clock
        self.write = write
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let now = clock()
        emit(ActivityEvent(t: now, kind: .displays, displays: source.displayCount))
        if let app = source.frontmostApp { receive(.activated(bundleID: app.bundleID, name: app.name), at: now) }
        source.start { [weak self] signal in self?.receive(signal) }
    }

    func stop() {
        guard isRunning else { return }
        flushPrivate(at: clock())
        source.stop()
        isRunning = false
        current = nil
        idleSince = nil
        asleepOrLocked = false
    }

    func receive(_ signal: ActivitySignal, at now: Date? = nil) {
        guard isRunning else { return }
        let now = now ?? clock()
        switch signal {
        case .activated(let bundleID, let name):
            flushPrivate(at: now)
            current = (bundleID, name)
            if isExcluded(bundleID, name) { privateSince = asleepOrLocked || idleSince != nil ? nil : now }
            else { emit(ActivityEvent(t: now, kind: .activate, app: bundleID, name: name)) }
        case .launched(let bundleID, let name):
            if !isExcluded(bundleID, name) { emit(ActivityEvent(t: now, kind: .launch, app: bundleID, name: name)) }
        case .quit(let bundleID, let name):
            if !isExcluded(bundleID, name) { emit(ActivityEvent(t: now, kind: .quit, app: bundleID, name: name)) }
        case .locked, .sleep:
            flushPrivate(at: now)
            asleepOrLocked = true
            emit(ActivityEvent(t: now, kind: signal == .locked ? .lock : .sleep))
        case .unlocked, .wake:
            asleepOrLocked = false
            // Unlocking is input; the idle poll must not also report a return.
            idleSince = nil
            emit(ActivityEvent(t: now, kind: signal == .unlocked ? .unlock : .wake))
            resumePrivate(at: now)
        case .displays(let count):
            emit(ActivityEvent(t: now, kind: .displays, displays: count))
        }
    }

    /// The idle poll: no input for 5 minutes starts an idle period at the last input; input again ends it.
    func tick(now: Date? = nil) {
        guard isRunning, !asleepOrLocked else { return }
        let now = now ?? clock()
        let idle = source.secondsSinceLastInput
        if idleSince == nil, idle >= Self.idleThreshold {
            let start = now.addingTimeInterval(-idle)
            flushPrivate(at: start)
            idleSince = start
            emit(ActivityEvent(t: start, kind: .idle))
        } else if idleSince != nil, idle < Self.idleThreshold {
            let back = now.addingTimeInterval(-idle)
            idleSince = nil
            emit(ActivityEvent(t: back, kind: .active))
            resumePrivate(at: back)
        }
    }

    private func resumePrivate(at date: Date) {
        if let app = current, isExcluded(app.bundleID, app.name) { privateSince = date }
    }
    private func flushPrivate(at end: Date) {
        guard let start = privateSince else { return }
        privateSince = nil
        let seconds = end.timeIntervalSince(start).rounded()
        if seconds >= 1 { emit(ActivityEvent(t: start, kind: .private, seconds: seconds)) }
    }
    private func emit(_ event: ActivityEvent) {
        guard !isPaused(event.t) else { return }
        write(event)
    }
}

/// The real source: `NSWorkspace` activation, launch and quit, sleep and wake, screen lock and unlock, display changes,
/// and `CGEventSource` for seconds since the last input. No permission needed.
@MainActor
final class WorkspaceActivitySource: ActivityEventSource {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start(_ handler: @escaping @MainActor (ActivitySignal) -> Void) {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        let appSignals: [(Notification.Name, @Sendable (String?, String?) -> ActivitySignal)] = [
            (NSWorkspace.didActivateApplicationNotification, { .activated(bundleID: $0, name: $1) }),
            (NSWorkspace.didLaunchApplicationNotification, { .launched(bundleID: $0, name: $1) }),
            (NSWorkspace.didTerminateApplicationNotification, { .quit(bundleID: $0, name: $1) }),
        ]
        for (name, make) in appSignals {
            observe(workspace, name) { note in let (id, title) = Self.app(note); return make(id, title) } handler: { handler($0) }
        }
        let plain: [(NotificationCenter, Notification.Name, ActivitySignal)] = [
            (workspace, NSWorkspace.willSleepNotification, .sleep),
            (workspace, NSWorkspace.willPowerOffNotification, .sleep),
            (workspace, NSWorkspace.didWakeNotification, .wake),
            (DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked"), .locked),
            (DistributedNotificationCenter.default(), .init("com.apple.screenIsUnlocked"), .unlocked),
        ]
        for (center, name, signal) in plain { observe(center, name) { _ in signal } handler: { handler($0) } }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { _ in
            .displays(MainActor.assumeIsolated { NSScreen.screens.count })
        } handler: { handler($0) }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    var secondsSinceLastInput: TimeInterval {
        // kCGAnyInputEventType: the time since any keyboard, mouse or tablet event.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
    var frontmostApp: (bundleID: String?, name: String?)? {
        NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier, $0.localizedName) }
    }
    var displayCount: Int { NSScreen.screens.count }

    nonisolated private static func app(_ note: Notification) -> (String?, String?) {
        let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return (running?.bundleIdentifier, running?.localizedName)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ signal: @escaping @Sendable (Notification) -> ActivitySignal,
                         handler: @escaping @MainActor (ActivitySignal) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            let value = signal(note)
            MainActor.assumeIsolated { handler(value) }
        }
        tokens.append((center, token))
    }
}
