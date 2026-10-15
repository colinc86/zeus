import Foundation
import Observation
import Testing
@testable import Zeus

@MainActor @Observable private final class AppScreenObserverFake: ScreenObserving {
    var permission = ScreenPermission.notDetermined
    var pause: ScreenPause?
    var lastError: String?
    var permissionGrantedRequiresReopen = false
    var starts = 0
    var stops = 0
    var invalidations = 0
    var requests = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func contextDidChange(returnedFromIdle: Bool) {}
    func requestPermission() -> ScreenPermission { requests += 1; return permission }
    func captureNow() {}
    func captureOnDemand() async -> ScreenCaptureResult? { nil }
    func invalidatePendingCapture() { invalidations += 1 }
}
@MainActor struct LM2BScreenIntegrationTests {
    @Test func productionAdapterStartsOnlyAfterConsentAndMapsPermissionAndHardStops() throws {
        let name = "zeus-screen-adapter-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let policies = ObservationSettings(defaults: defaults), source = LM2FocusSource()
        let learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil)
        let fake = AppScreenObserverFake()
        let model = ScreenLearningModel(policies: policies, learn: learn,
            journal: EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey()), redactor: LocalRedactor(), focus: source, injectedObserver: fake)
        defer { model.stop() }
        model.settingsChanged(); #expect(fake.starts == 0); #expect(fake.requests == 0)
        model.privacy.setEnabled(true); #expect(model.privacy.showsConsent); #expect(fake.starts == 0)
        model.privacy.continueConsent(); #expect(fake.starts == 1); #expect(fake.requests == 1)
        fake.permission = .granted; fake.pause = .camera; model.syncPresentation()
        #expect(model.privacy.statusCaption == "Paused: a video call is on")
        fake.pause = .presenting; model.syncPresentation(); #expect(model.privacy.statusCaption == "Paused: presenting")
        fake.permission = .revoked; model.syncPresentation(); #expect(model.privacy.permission == .revoked)
        fake.permissionGrantedRequiresReopen = true; model.syncPresentation(); #expect(model.privacy.permission == .reopenRequired)
        model.privacy.setEnabled(false); #expect(fake.stops > 0); #expect(fake.requests == 1)
    }
    @Test func pauseDeadlineRestartsWithoutAnyLevelOneTimerOrPreferenceEdit() async throws {
        let name = "zeus-screen-deadline-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(600)
        let policies = ObservationSettings(defaults: defaults), learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil, clock: { now })
        policies.edit(3) { $0.enabled = true; $0.consented = true }; learn.settings.pausedUntil = deadline
        var waited: Date?, resume: CheckedContinuation<Void, Never>?
        let fake = AppScreenObserverFake()
        let model = ScreenLearningModel(policies: policies, learn: learn,
            journal: EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey()), redactor: LocalRedactor(), focus: LM2FocusSource(), injectedObserver: fake,
            clock: { now }, waitUntil: { at in waited = at; await withCheckedContinuation { resume = $0 } })
        defer { resume?.resume(); model.stop() }
        model.settingsChanged(); #expect(fake.starts == 0)
        for _ in 0..<100 { if waited != nil { break }; await Task.yield() }
        #expect(waited == deadline)
        now = deadline; resume?.resume(); resume = nil
        for _ in 0..<100 { if fake.starts == 1 { break }; await Task.yield() }
        #expect(fake.starts == 1); #expect(!learn.isPausedNow)
        let safari = ScreenCaptureIdentity(bundleID: "com.apple.Safari", processID: 42, windowID: 1)
        #expect(model.browserPrivacy(safari) == .unknown)
        policies.edit(3) { $0.scope = .chosenApps; $0.apps = [.init(name: "Safari", bundleIDs: ["com.apple.Safari"])] }
        #expect(model.browserPrivacy(safari) == .normal)
        #expect(model.browserPrivacy(.init(bundleID: "unclassified.browser", processID: 42, windowID: 1)) == .unknown)
    }
    @Test func adapterNeverUsesDormantAllowListAsDenyListAndL3KeepsOwnRetention() throws {
        let name = "zeus-screen-policy-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let policies = ObservationSettings(defaults: defaults), source = LM2FocusSource()
        let learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil)
        policies.edit(3) { $0.enabled = true; $0.consented = true; $0.apps = [.init(name: "Editor", bundleIDs: ["test.editor"])]; $0.retentionDays = 7 }
        let fake = AppScreenObserverFake()
        let model = ScreenLearningModel(policies: policies, learn: learn,
            journal: EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey()), redactor: LocalRedactor(), focus: source, injectedObserver: fake)
        defer { model.stop() }
        let context = ScreenContext(bundleID: "test.editor", appName: "Editor", windowTitle: "", windowID: 1, processID: 42)
        #expect(model.policy.apps.isEmpty); #expect(model.policy.permits(context)); #expect(model.policy.descriptionRetentionDays == 7)
        policies.edit(3) { $0.scope = .chosenApps }; #expect(model.policy.apps == ["test.editor"])
        learn.settings.excludedApps.append(.init(name: "Editor", bundleIDs: []))
        #expect(!model.policy.permits(context))
        learn.settings.excludedApps.removeAll(); model.privacy.pause()
        #expect(!model.policy.enabled); model.privacy.resume(); #expect(model.policy.enabled)
    }
}
