import Foundation
import Testing
@testable import Zeus

@MainActor struct LM2BScreenSettingsTests {
    private func fixture() throws -> (String, UserDefaults, ObservationSettings, ScreenPrivacyModel) {
        let name = TestDefaults.suite("zeus-screen-settings"), defaults = try #require(UserDefaults(suiteName: name))
        let settings = ObservationSettings(defaults: defaults)
        return (name, defaults, settings, ScreenPrivacyModel(policies: settings, privacy: LearnSettings(defaults: defaults)))
    }
    @Test func screenStartsOffAndConsentCancelHasNoEffect() throws {
        let (name, defaults, settings, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0; model.requestPermission = { requests += 1 }
        #expect(!model.isEnabled); #expect(settings.screenPerHour == 12)
        model.setEnabled(true); #expect(model.showsConsent); #expect(!model.policy.enabled)
        model.cancelConsent(); #expect(!model.showsConsent); #expect(!model.policy.consented); #expect(requests == 0)
        model.continueConsent(); #expect(requests == 0)
    }
    @Test func onlyExplicitFirstConsentRequestsPermissionAndRevocationDoesNotReprompt() throws {
        let (name, defaults, settings, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0; model.requestPermission = { requests += 1 }
        model.setEnabled(true); model.continueConsent()
        #expect(model.isEnabled); #expect(model.permission == .waiting); #expect(requests == 1)
        #expect(settings.screenPermissionRequested)
        model.permission = .revoked; model.setEnabled(false); model.setEnabled(true)
        #expect(model.permission == .revoked); #expect(requests == 1)
        #expect(ObservationSettings(defaults: defaults).screenPermissionRequested)
    }
    @Test func existingPermissionDoesNotRequestItAgain() throws {
        let (name, defaults, _, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0; model.requestPermission = { requests += 1 }; model.permission = .granted
        model.setEnabled(true); model.continueConsent()
        #expect(model.isEnabled); #expect(requests == 0)
    }
    @Test func independentScreenScopePersistsWhileSharedPrivateListAlwaysWins() throws {
        let (name, defaults, settings, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        settings.edit(3) { $0.scope = .chosenApps; $0.apps = [.init(name: "Editor", bundleIDs: ["test.editor"])]; $0.retentionDays = 7 }
        #expect(model.policy.allows(bundleID: "test.editor", name: "Editor", privateApps: []))
        #expect(!model.policy.allows(bundleID: "test.editor", name: "Editor", privateApps: model.policy.apps))
        #expect(settings.policy(2).scope == .exceptPrivate)
        settings.screenPerHour = 30
        let restored = ObservationSettings(defaults: defaults)
        #expect(restored.policy(3).retentionDays == 7); #expect(restored.screenPerHour == 30)
        settings.screenPerHour = 1; #expect(settings.screenPerHour == 12)
        #expect(ObservationSettings(defaults: defaults).screenPerHour == 12)
        settings.edit(5) { $0.enabled = true }; #expect(!settings.policy(5).enabled)
    }
    @Test func permissionStatesWinOverHardStopsAndPausedCopyIsQuiet() throws {
        let (name, defaults, settings, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        settings.edit(3) { $0.enabled = true; $0.consented = true }
        model.pauseReason = .videoCall; model.permission = .granted
        #expect(model.statusCaption == "Paused: a video call is on")
        model.pauseReason = .presenting; #expect(model.statusCaption == "Paused: presenting")
        model.pauseReason = .secureInput; #expect(model.statusCaption == "Paused: a password field is active")
        model.permission = .reopenRequired; #expect(model.statusCaption == "Allowed. Reopen Zeus to start taking pictures.")
        model.permission = .denied; #expect(model.statusCaption == "Screen Recording is off for Zeus, so no pictures are taken.")
    }
}
