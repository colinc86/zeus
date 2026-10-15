import AppKit
import FoundationModels
import Observation

/// App-owned consent/scope adapter. The core owns every key, run, redaction and permission watchdog.
@MainActor @Observable final class TypingLearningModel {
    let privacy: TypingPrivacyModel
    @ObservationIgnored let focus: any FocusCaptureSource
    private(set) var observer: (any TypingObserving)?
    @ObservationIgnored private let learn: LearnFromMe
    @ObservationIgnored private let modelAvailable: () -> Bool
    @ObservationIgnored private var windowSource: TypingWindowContextSource?
    @ObservationIgnored private var normalBrowser: ScreenCaptureIdentity?
    @ObservationIgnored private var browserTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let waitUntil: (Date) async throws -> Void
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var requestedThisLaunch = false
    init(policies: ObservationSettings, learn: LearnFromMe, journal: any TypingJournalStoring,
         redactor: any Redactor, focus: any FocusCaptureSource, injectedObserver: (any TypingObserving)? = nil,
         modelAvailable: @escaping () -> Bool = { SystemLanguageModel.default.isAvailable },
         clock: @escaping () -> Date = Date.init, waitUntil: ((Date) async throws -> Void)? = nil) {
        privacy = TypingPrivacyModel(policies: policies, privacy: learn.settings)
        self.learn = learn; self.focus = focus; self.clock = clock; self.modelAvailable = modelAvailable
        self.waitUntil = waitUntil ?? { deadline in try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(clock())))) }
        if let injectedObserver { observer = injectedObserver }
        else {
            windowSource = TypingWindowContextSource(policy: { [weak self] in self?.policy ?? .init() },
                isLocked: { [weak focus] in focus?.isLocked ?? true },
                browserPrivacy: { [weak self] in self?.browserPrivacy($0) ?? .unknown })
            observer = TypingObserver(journal: journal, redactor: redactor, policy: { [weak self] in self?.policy ?? .init() },
                context: { [weak self] in self?.windowSource?.current() })
        }
        privacy.changed = { [weak self] in self?.settingsChanged() }
        privacy.requestPermission = { [weak self] in
            self?.requestedThisLaunch = true; _ = self?.observer?.requestPermission(); self?.syncPresentation()
        }
        privacy.openPermissionSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
        }
        privacy.paused = { [weak learn] in learn?.isPausedNow ?? true }
        syncPresentation()
    }
    var policy: TypingPolicy {
        let value = privacy.policy
        var result = TypingPolicy()
        result.enabled = value.enabled && !learn.isPausedNow; result.consented = value.consented
        result.apps = Set(value.apps.flatMap(\.bundleIDs))
        result.privateApps = Set(learn.settings.excludedApps.flatMap(\.bundleIDs)); result.privateApps.insert("com.colinc86.Zeus")
        if let app = focus.application,
           app.bundleID.hasPrefix("local.zeus.") || learn.settings.excludedApps.contains(where: { $0.matches(bundleID: app.bundleID, name: app.name) }) {
            result.privateApps.insert(app.bundleID)
        }
        result.words = switch privacy.policies.typingWordsHours { case 0: .none; case 168: .week; default: .day }
        result.topicRetentionDays = value.retentionDays
        return result
    }
    func settingsChanged() {
        resumeTask?.cancel(); resumeTask = nil
        if let deadline = learn.settings.pausedUntil, deadline > clock() {
            let waitUntil = waitUntil
            resumeTask = Task { @MainActor [weak self] in
                do { try await waitUntil(deadline) } catch { return }
                guard let self, !Task.isCancelled else { return }; settingsChanged()
            }
        }
        invalidate()
        if policy.enabled && policy.consented {
            if !running { running = true; windowSource?.start { [weak self] in self?.contextChanged() }; observer?.start() }
            contextChanged()
        } else { running = false; windowSource?.stop(); observer?.stop() }
        syncPresentation()
        if !observing { observing = true; observePresentation() }
    }
    func contextChanged() {
        normalBrowser = nil; browserTask?.cancel(); observer?.contextDidChange()
        guard running, let source = focus as? MacFocusCaptureSource, let app = focus.application,
              ScreenLearningModel.chromium(app.bundleID), let identity = source.frontWindowIdentity(app),
              privacy.policy.allows(bundleID: app.bundleID, name: app.name, privateApps: learn.settings.excludedApps) else { return }
        browserTask = Task { @MainActor [weak self] in
            guard await source.isNormalBrowserWindow(app, identity: identity), !Task.isCancelled, let self,
                  running, source.frontWindowIdentity(app) == identity else { return }
            normalBrowser = identity; observer?.contextDidChange()
        }
    }
    func browserPrivacy(_ identity: ScreenCaptureIdentity) -> BrowserWindowPrivacy {
        if identity.bundleID == "com.apple.Safari", privacy.policy.permitsSafariDetails { return .normal }
        return normalBrowser == identity ? .normal : .unknown
    }
    func syncPresentation() {
        privacy.modelAvailable = modelAvailable(); privacy.secureInput = focus.isSecure || observer?.privateInput == true
        guard let observer else { return }
        if observer.permissionGrantedRequiresReopen { privacy.permission = .reopenRequired }
        else {
            privacy.permission = switch observer.permission {
            case .granted: .granted
            case .revoked: .revoked
            case .denied: .denied
            case .notDetermined: privacy.policies.typingPermissionRequested ? (requestedThisLaunch ? .waiting : .denied) : .notRequested
            }
        }
    }
    func invalidate() { browserTask?.cancel(); browserTask = nil; observer?.invalidatePendingCapture() }
    func stop() { observing = false; running = false; resumeTask?.cancel(); resumeTask = nil; invalidate(); windowSource?.stop(); observer?.stop() }
    isolated deinit { resumeTask?.cancel(); browserTask?.cancel() }
    private func observePresentation() {
        guard observing else { return }
        withObservationTracking {
            _ = observer?.permission; _ = observer?.permissionGrantedRequiresReopen; _ = observer?.privateInput
            _ = observer?.pause; _ = observer?.lastError; _ = observer?.isRecording
        } onChange: { [weak self] in Task { @MainActor [weak self] in
            guard let self, observing else { return }; syncPresentation(); observePresentation()
        } }
    }
}
