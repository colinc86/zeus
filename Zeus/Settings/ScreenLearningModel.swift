import AppKit
import FoundationModels
import Observation

/// Connects explicit app preferences to the capture capability; creation never requests permission.
@MainActor @Observable final class ScreenLearningModel {
    let privacy: ScreenPrivacyModel
    private(set) var observer: (any ScreenObserving)?
    @ObservationIgnored private let learn: LearnFromMe
    @ObservationIgnored private let focus: any FocusCaptureSource
    @ObservationIgnored private var windowSource: ScreenWindowContextSource?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private let waitUntil: (Date) async throws -> Void
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var browserTask: Task<Void, Never>?
    @ObservationIgnored private var normalBrowser: ScreenCaptureIdentity?
    @ObservationIgnored private var previousIdle = false

    init(policies: ObservationSettings, learn: LearnFromMe, journal: any FrameJournalStoring,
         redactor: any Redactor, focus: any FocusCaptureSource,
         injectedObserver: (any ScreenObserving)? = nil, clock: @escaping () -> Date = Date.init, waitUntil: ((Date) async throws -> Void)? = nil) {
        privacy = ScreenPrivacyModel(policies: policies, privacy: learn.settings)
        self.learn = learn; self.focus = focus; self.clock = clock
        self.waitUntil = waitUntil ?? { deadline in try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(clock())))) }
        if let injectedObserver { observer = injectedObserver }
        else {
            windowSource = ScreenWindowContextSource(policy: { [weak self] in self?.policy ?? ScreenPolicy() },
                isLocked: { [weak focus] in focus?.isLocked ?? true },
                browserPrivacy: { [weak self] identity in self?.browserPrivacy(identity) ?? .unknown })
            observer = ScreenObserver(journal: journal, redactor: redactor,
                policy: { [weak self] in self?.policy ?? ScreenPolicy() },
                context: { [weak self] in self?.windowSource?.current() })
        }
        privacy.modelAvailable = SystemLanguageModel.default.isAvailable
        privacy.requestPermission = { [weak self] in self?.requestPermission() }
        privacy.openPermissionSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        }
        privacy.pause = { [weak learn] in learn?.pauseForToday() }
        privacy.resume = { [weak learn] in learn?.resume() }
        privacy.isPaused = { [weak learn] in learn?.isPausedNow ?? true }
        privacy.changed = { [weak self] in self?.settingsChanged() }
        syncPresentation()
    }
    var policy: ScreenPolicy {
        let value = privacy.policy
        var result = ScreenPolicy()
        result.enabled = value.enabled && !learn.isPausedNow
        result.consented = value.consented
        result.scope = value.scope == .chosenApps ? .onlyChosen : .everywhereExcept
        result.apps = value.scope == .chosenApps ? Set(value.apps.flatMap(\.bundleIDs)) : []
        result.privateApps = Set(learn.settings.excludedApps.flatMap(\.bundleIDs))
        result.privateApps.insert("com.colinc86.Zeus")
        // Names in imported private lists must have the same authority as bundle identifiers.
        if let app = focus.application,
           app.bundleID.hasPrefix("local.zeus.") || learn.settings.excludedApps.contains(where: { $0.matches(bundleID: app.bundleID, name: app.name) }) {
            result.privateApps.insert(app.bundleID)
        }
        result.capturesPerHour = privacy.policies.screenPerHour
        result.descriptionRetentionDays = value.retentionDays
        return result
    }
    func settingsChanged() {
        resumeTask?.cancel(); resumeTask = nil
        if let deadline = learn.settings.pausedUntil, deadline > clock() {
            let waitUntil = waitUntil
            resumeTask = Task { @MainActor [weak self] in
                do { try await waitUntil(deadline) } catch { return }
                guard let self, !Task.isCancelled else { return }
                settingsChanged()
            }
        }
        invalidate()
        if policy.enabled && policy.consented {
            if !running {
                running = true
                windowSource?.start { [weak self] in self?.contextChanged() }
                observer?.start()
            }
            contextChanged()
        } else {
            running = false; windowSource?.stop(); observer?.stop()
        }
        syncPresentation()
        if !observing { observing = true; observePresentation() }
    }
    func invalidate() { browserTask?.cancel(); browserTask = nil; observer?.invalidatePendingCapture() }
    isolated deinit { resumeTask?.cancel(); browserTask?.cancel() }
    func stop() { resumeTask?.cancel(); resumeTask = nil; running = false; observing = false; invalidate(); windowSource?.stop(); observer?.stop() }
    func contextChanged() {
        normalBrowser = nil
        observer?.contextDidChange(returnedFromIdle: previousIdle && focus.idleSeconds < 60)
        previousIdle = focus.idleSeconds >= 60
        browserTask?.cancel()
        // A normal window is established positively by the same bound Chromium window mode used by L2.
        guard running, let source = focus as? MacFocusCaptureSource, let app = focus.application,
              Self.chromium(app.bundleID), let identity = source.frontWindowIdentity(app),
              privacy.policy.allows(bundleID: app.bundleID, name: app.name, privateApps: learn.settings.excludedApps) else { return }
        browserTask = Task { @MainActor [weak self] in
            guard await source.isNormalBrowserWindow(app, identity: identity), !Task.isCancelled, let self,
                  running, source.frontWindowIdentity(app) == identity else { return }
            normalBrowser = identity; observer?.contextDidChange(returnedFromIdle: false)
        }
    }
    /// Safari is the explicit PM-approved exception: its allow list includes private windows too.
    func browserPrivacy(_ identity: ScreenCaptureIdentity) -> BrowserWindowPrivacy {
        if identity.bundleID == "com.apple.Safari", privacy.policy.permitsSafariDetails { return .normal }
        return normalBrowser == identity ? .normal : .unknown
    }
    static func chromium(_ id: String) -> Bool { id.hasPrefix("com.google.Chrome") || id == "com.microsoft.edgemac" }
    private func requestPermission() { _ = observer?.requestPermission(); syncPresentation() }
    func syncPresentation() {
        guard let observer else { return }
        if observer.permissionGrantedRequiresReopen { privacy.permission = .reopenRequired }
        else {
            switch observer.permission {
            case .granted: privacy.permission = .granted
            case .revoked: privacy.permission = .revoked
            case .denied: privacy.permission = .denied
            case .notDetermined: privacy.permission = privacy.policies.screenPermissionRequested ? .waiting : .notRequested
            }
        }
        privacy.pauseReason = switch observer.pause {
        case .camera: .videoCall
        case .presenting: .presenting
        case .secureInput: .secureInput
        default: nil
        }
    }
    private func observePresentation() {
        guard observing else { return }
        withObservationTracking {
            _ = observer?.permission; _ = observer?.pause; _ = observer?.lastError
            _ = observer?.permissionGrantedRequiresReopen
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, observing else { return }; syncPresentation(); observePresentation()
            }
        }
    }
}
