import Foundation
import Testing
@testable import Zeus

@MainActor struct LM2CTypingSettingsTests {
    private func fixture() throws -> (String, UserDefaults, ObservationSettings, TypingPrivacyModel) {
        let name = "zeus-typing-ui-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        let policies = ObservationSettings(defaults: defaults)
        return (name, defaults, policies, TypingPrivacyModel(policies: policies, privacy: LearnSettings(defaults: defaults)))
    }
    @Test func independentDefaultsAlwaysRestrictTypingToChosenApps() throws {
        let (name, defaults, settings, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(!model.isEnabled); #expect(model.policy.scope == .chosenApps)
        #expect(model.policy.retentionDays == 30); #expect(settings.typingWordsHours == 24)
        settings.edit(4) { $0.scope = .exceptPrivate; $0.retentionDays = 500 }
        #expect(model.policy.scope == .chosenApps); #expect(model.policy.retentionDays == 30)
        settings.edit(4) { $0.retentionDays = 7 }; settings.typingWordsHours = 168
        let restored = ObservationSettings(defaults: defaults)
        #expect(restored.policy(4).retentionDays == 7); #expect(restored.typingWordsHours == 168)
        #expect(restored.policy(3).retentionDays == 90)
        settings.typingWordsHours = 5
        #expect(ObservationSettings(defaults: defaults).typingWordsHours == 24)
    }
    @Test func modelRequiredAndCancelNeverEnablesOrRequestsPermission() throws {
        let (name, defaults, _, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0; model.requestPermission = { requests += 1 }
        model.setEnabled(true); #expect(!model.showsConsent); #expect(!model.isEnabled)
        #expect(model.statusCaption == TypingPrivacyModel.modelCaption)
        model.modelAvailable = true; model.setEnabled(true); #expect(model.showsConsent)
        model.cancelConsent(); model.continueConsent()
        #expect(!model.isEnabled); #expect(requests == 0)
    }
    @Test func firstConsentChoosesAppsBeforeRequestAndPickerCancelIsSafe() throws {
        let (name, defaults, settings, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0; model.requestPermission = { requests += 1 }; model.modelAvailable = true
        model.setEnabled(true); model.continueConsent()
        #expect(model.isEnabled); #expect(model.needsAppPicker); #expect(requests == 0)
        model.completeAppSelection() // User cancels; nothing can be recorded without an allow-list entry.
        #expect(model.policy.apps.isEmpty); #expect(requests == 1); #expect(model.permission == .waiting)
        #expect(settings.typingPermissionRequested)
        model.permission = .revoked; model.setEnabled(false); model.setEnabled(true); model.completeAppSelection()
        #expect(requests == 1); #expect(model.permission == .revoked)
    }
    @Test func privateListWinsAndExistingPermissionDoesNotReprompt() throws {
        let (name, defaults, _, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let app = ExcludedApp(name: "Test Editor", bundleIDs: ["test.editor"])
        model.privacy.excludedApps = [app]; model.addApp(app)
        #expect(model.policy.apps.isEmpty)
        #expect(model.appResult == "Test Editor is on your private list. Remove it there first.")
        model.privacy.excludedApps = []; model.addApp(app)
        var requests = 0; model.requestPermission = { requests += 1 }; model.permission = .granted; model.modelAvailable = true
        model.setEnabled(true); model.continueConsent()
        #expect(!model.needsAppPicker); #expect(requests == 0)
    }
    @Test func shorteningRetentionPrunesImmediatelyAndDoesNotClaimFailedDeletes() throws {
        let (name, defaults, _, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        var prunes = 0; model.shortenRetention = { prunes += 1; return true }
        model.setTopics(90); #expect(prunes == 0)
        model.setTopics(7); #expect(prunes == 1); #expect(model.keepCaption == "Deleted topics older than 7 days.")
        model.setWords(0); #expect(prunes == 2); #expect(model.keepCaption == "Deleted the kept words.")
        model.setWords(168); model.setWords(24)
        #expect(model.keepCaption == "Deleted words older than 24 hours.")
        model.shortenRetention = { false }; model.setWords(0)
        #expect(model.keepCaption == "Couldn't remove expired typing. Try again.")
    }
    @Test func privateInputIsQuietAndOnlyShownWhenTypingIsEnabled() throws {
        let (name, defaults, settings, model) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        model.modelAvailable = true; model.secureInput = true; model.permission = .granted
        #expect(!model.showsPrivateInput)
        settings.edit(4) { $0.enabled = true; $0.consented = true }
        #expect(model.showsPrivateInput); #expect(model.statusCaption == "Paused: private input.")
        model.permission = .denied; #expect(model.statusCaption == "Input Monitoring is off for Zeus, so nothing you type is noted.")
        model.permission = .reopenRequired; #expect(model.statusCaption == "Allowed. Reopen Zeus to start.")
        model.secureInput = false; #expect(!model.showsPrivateInput)
    }
}
