import Foundation
import Observation
import Testing
@testable import Zeus

@MainActor @Observable private final class AppTypingObserverFake: TypingObserving {
    var permission = TypingPermission.notDetermined
    var lastPermissionRequestGranted: Bool?
    var privateInput = false
    var isRecording = false
    var pause: TypingPause?
    var lastError: String?
    var starts = 0
    var stops = 0
    var requests = 0
    var invalidations = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func requestPermission() -> TypingPermission { requests += 1; return permission }
    func contextDidChange() {}
    func invalidatePendingCapture() { invalidations += 1 }
}
@MainActor struct LM2CTypingIntegrationTests {
    @Test func consentPermissionPrivateInputAndRevocationUseTheCoreFacts() throws {
        let name = "zeus-typing-adapter-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let policies = ObservationSettings(defaults: defaults), learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil)
        let fake = AppTypingObserverFake(), source = LM2FocusSource()
        let model = TypingLearningModel(policies: policies, learn: learn,
            journal: EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey()), redactor: LocalRedactor(useOnDeviceModel: false),
            focus: source, injectedObserver: fake, modelAvailable: { true })
        defer { model.stop() }
        model.settingsChanged(); #expect(fake.starts == 0); #expect(fake.requests == 0)
        model.privacy.setEnabled(true); model.privacy.continueConsent(); #expect(model.privacy.needsAppPicker)
        model.privacy.completeAppSelection(); #expect(fake.starts == 1); #expect(fake.requests == 1)
        fake.permission = .granted; fake.privateInput = true; model.syncPresentation()
        #expect(model.privacy.statusCaption == "Paused: private input.")
        fake.permission = .revoked; model.syncPresentation(); #expect(model.privacy.permission == .revoked)
        fake.lastPermissionRequestGranted = true; model.syncPresentation(); #expect(model.privacy.permission == .reopenRequired)
        model.privacy.setEnabled(false); #expect(fake.stops > 0); #expect(fake.requests == 1)
    }
    @Test func pauseExpiresWithoutLevelOneAndSafariRequiresExplicitChoice() async throws {
        let name = "zeus-typing-pause-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000); let deadline = now.addingTimeInterval(300)
        let policies = ObservationSettings(defaults: defaults), learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil, clock: { now })
        policies.edit(4) { $0.enabled = true; $0.consented = true }; learn.settings.pausedUntil = deadline
        let fake = AppTypingObserverFake(); var waited: Date?, resume: CheckedContinuation<Void, Never>?
        let model = TypingLearningModel(policies: policies, learn: learn,
            journal: EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey()), redactor: LocalRedactor(useOnDeviceModel: false),
            focus: LM2FocusSource(), injectedObserver: fake, modelAvailable: { true }, clock: { now },
            waitUntil: { at in waited = at; await withCheckedContinuation { resume = $0 } })
        defer { resume?.resume(); model.stop() }
        model.settingsChanged(); #expect(fake.starts == 0)
        for _ in 0..<100 { if waited != nil { break }; await Task.yield() }
        #expect(waited == deadline); now = deadline; resume?.resume(); resume = nil
        for _ in 0..<100 { if fake.starts == 1 { break }; await Task.yield() }
        #expect(fake.starts == 1)
        let safari = ScreenCaptureIdentity(bundleID: "com.apple.Safari", processID: 42, windowID: 1)
        #expect(model.browserPrivacy(safari) == .unknown)
        policies.edit(4) { $0.apps = [.init(name: "Safari", bundleIDs: ["com.apple.Safari"])] }
        #expect(model.browserPrivacy(safari) == .normal)
        learn.settings.excludedApps.append(.init(name: "Safari", bundleIDs: []))
        #expect(!model.privacy.policy.allows(bundleID: "com.apple.Safari", name: "Safari", privateApps: learn.settings.excludedApps))
    }
    @Test func privateInputOnlyAddsADisabledMenuLineWithoutTouchingCardsOrAvatar() throws {
        let name = "zeus-typing-menu-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let shell = ShellController(defaults: defaults, cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), settings: settings)
        let source = LM2FocusSource(); source.isSecure = true
        shell.learning.install(journal: LM2JournalFake(), rules: LM2RulesFake(), redactor: LocalRedactor(useOnDeviceModel: false), source: source)
        defer { shell.learning.stop() }
        let line = "Private input: Zeus isn't noting typing"
        #expect(!shell.menuModel.outline.contains(line + " (disabled)"))
        shell.learning.policies.edit(4) { $0.enabled = true; $0.consented = true }
        #expect(shell.menuModel.outline.contains(line + " (disabled)"))
        let native = shell.menuModel.makeNSMenu(perform: { _ in })
        let item = try #require(native.items.first { $0.title == line }); #expect(!item.isEnabled); #expect(item.action == nil)
        #expect(shell.cards.cards.isEmpty); #expect(shell.cards.notices.isEmpty)
        source.isSecure = false; #expect(!shell.menuModel.outline.contains(line + " (disabled)"))
    }
    @Test func selectedTopicRetentionAndWordsSplitReachTheEncryptedStoreEvenWhenCaptureIsOff() throws {
        let name = "zeus-typing-retention-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), store = EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey(), clock: { now })
        for (id, age) in [("old", 45.0), ("week", 8.0), ("today", 0.1)] {
            try store.append(.init(id: id, time: now.addingTimeInterval(-age * 86400), level: .typed, app: "test.editor", kind: .typedText,
                payload: .init(.init(description: "Typing", text: "safe synthetic words", topic: "Planning source changes",
                    details: ["topic_expires": String(now.addingTimeInterval((90 - age) * 86400).timeIntervalSince1970)]))))
        }
        let policies = ObservationSettings(defaults: defaults); policies.edit(4) { $0.retentionDays = 90 }
        let learning = LearningPresentation(defaults: defaults, learn: LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil), policies: policies)
        learning.install(journal: store, rules: LM2RulesFake(), redactor: LocalRedactor(useOnDeviceModel: false), source: LM2FocusSource())
        defer { learning.stop() }
        #expect(try store.items(matching: .init()).count == 3)
        let privacy = try #require(learning.typing?.privacy)
        privacy.setTopics(7)
        #expect(try store.items(matching: .init()).map(\.id) == ["today"])
        privacy.setWords(0)
        let row = try #require(store.items(matching: .init()).first)
        #expect(row.payload.value.text == nil); #expect(row.payload.value.topic == "Planning source changes")
        #expect(row.payload.value.details["words_not_kept"] == "setting")
        #expect(learning.viewer?.items.allSatisfy { $0.payload.value.text == nil } == true)
    }
}
