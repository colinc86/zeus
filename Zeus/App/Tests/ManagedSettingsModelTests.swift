import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Observable private final class SettingsApplyController: ManagedSessionControlling, ManagedSettingsApplying {
    var managedStatus: ManagedSessionStatus = .running(.idle)
    var managedTmuxSessionName: String? = "zeus"
    var managedAttachCommand: String? = "tmux attach -t zeus"
    var managedAppliedConfiguration: ManagedSessionConfig?
    var managedSettingsApplication: ManagedSettingsApplication?
    var managedSettingsApplicationError: String?
    var managedCanResumeSettings = true
    var supportsInstructions = true
    var requests: [ManagedSettingsApplication] = []
    var lifecycleCalls: [String] = []
    func supportsInstructionChangesOnResume(for agent: AgentKind) -> Bool { supportsInstructions }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        [.init(id: "ask", title: "Ask first", detail: "Asks first", isUnrestricted: false, isDefault: true),
         .init(id: "read", title: "Read only", detail: "Read", isUnrestricted: false, isDefault: false),
         .init(id: "full", title: "Unrestricted", detail: "Full", isUnrestricted: true, isDefault: false)]
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { nil }
    func applyManagedSettings(_ configuration: ManagedSessionConfig) { request(configuration, kind: .resume) }
    func switchManagedSettings(_ configuration: ManagedSessionConfig) { request(configuration, kind: .newConversation) }
    private func request(_ configuration: ManagedSessionConfig, kind: ManagedSettingsApplication.Kind) {
        let value = ManagedSettingsApplication(id: UUID(), configuration: configuration, kind: kind)
        requests.append(value); managedSettingsApplication = value
    }
    func cancelManagedSettingsApplication() { managedSettingsApplication = nil; managedSettingsApplicationError = nil }
    func complete() {
        managedAppliedConfiguration = managedSettingsApplication?.configuration
        managedSettingsApplication = nil
    }
    func startManagedSession() { lifecycleCalls.append("start") }
    func stopManagedSession() { lifecycleCalls.append("stop") }
    func restartManagedSession() { lifecycleCalls.append("restart") }
    func startNewManagedConversation() { lifecycleCalls.append("new") }
    func openManagedSessionInTerminal() { lifecycleCalls.append("terminal") }
}

@MainActor private struct SettingsApplyFixture {
    let defaults: UserDefaults
    let suite = "zeus-s3-ui-\(UUID())"
    let settings: AppSettings
    let controller: SettingsApplyController
    let model: ManagedAssistantModel
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        var config = AppSettings.newManagedSession(); config.folder = "/fixture"
        settings.managedSession = config; settings.managedLaunchedConfig = config
        controller = SettingsApplyController(); controller.managedAppliedConfiguration = config
        let controller = controller
        model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
    }
    func cleanup() { model.finishInstructionsEditing(); defaults.removePersistentDomain(forName: suite) }
}

@MainActor struct ManagedSettingsModelTests {
    @Test func instructionTypingCoalescesAndBlurRequestsOnlyTheLatestSnapshot() throws {
        let f = try SettingsApplyFixture(); defer { f.cleanup() }
        f.model.update { $0.launchPrompt = "F" }
        f.model.update { $0.launchPrompt = "First edit" }
        f.model.update { $0.launchPrompt = "Final edit\nSecond line" }
        #expect(f.controller.requests.isEmpty && f.model.instructionsAreDebouncing)
        #expect(f.settings.managedSession?.launchPrompt == "Final edit\nSecond line")
        f.model.finishInstructionsEditing()
        #expect(f.controller.requests.count == 1)
        #expect(f.controller.requests.first?.configuration.launchPrompt == "Final edit\nSecond line")
        #expect(f.controller.requests.first?.kind == .resume)
        #expect(f.controller.lifecycleCalls.isEmpty)
        f.model.finishInstructionsEditing()
        #expect(f.controller.requests.count == 1)
    }
    @Test func laterEditsReplacePendingRequestAndRevertingClearsIt() throws {
        let f = try SettingsApplyFixture(); defer { f.cleanup() }
        f.controller.managedStatus = .running(.working)
        f.model.choosePermission("read")
        #expect(f.model.note?.contains("finishes") == true)
        f.model.update { $0.launchPrompt = "New instructions" }
        #expect(f.controller.managedSettingsApplication == nil, "Stale requests cannot apply during the debounce")
        f.model.finishInstructionsEditing()
        #expect(f.controller.managedSettingsApplication?.configuration.permissionModeID == "read")
        #expect(f.controller.managedSettingsApplication?.configuration.launchPrompt == "New instructions")
        let original = try #require(f.controller.managedAppliedConfiguration)
        f.model.update { $0 = original }
        #expect(f.controller.managedSettingsApplication == nil && !f.model.needsRestart && f.model.note == nil)
        #expect(f.controller.lifecycleCalls.isEmpty)
    }
    @Test func unrestrictedKeepsConfirmationBeforeAnyRequest() throws {
        let f = try SettingsApplyFixture(); defer { f.cleanup() }
        f.model.choosePermission("full")
        #expect(f.model.confirmation != nil && f.controller.requests.isEmpty && f.model.config.permissionModeID == nil)
        f.model.cancelConfirmation()
        #expect(f.controller.requests.isEmpty)
        f.model.choosePermission("full"); f.model.confirm()
        #expect(f.controller.requests.count == 1 && f.controller.requests.first?.configuration.permissionModeID == "full")
    }
    @Test func laterNeverSwitchesAndExplicitSwitchUsesSeparateCapability() throws {
        let f = try SettingsApplyFixture(); defer { f.cleanup() }
        f.model.chooseAgent(.codex)
        #expect(f.model.confirmation == .switchConversation && f.controller.requests.isEmpty)
        #expect(f.model.switchConfirmation.contains("Claude Code's conversation stays in /fixture"))
        f.model.cancelConfirmation()
        #expect(f.model.note?.contains("Switches to Codex") == true && f.controller.requests.isEmpty)
        f.model.perform(.restart); f.model.confirm()
        #expect(f.controller.requests.count == 1 && f.controller.requests.first?.kind == .newConversation)
        #expect(f.model.agentName == "Claude Code", "A queued switch does not relabel the running session")
        #expect(f.controller.lifecycleCalls.isEmpty)
        f.controller.complete()
        #expect(f.model.agentName == "Codex" && !f.model.needsRestart)
    }
    @Test func startupOnlyChangeNeverRestartsOrReplacesAPendingApply() throws {
        let f = try SettingsApplyFixture(); defer { f.cleanup() }
        f.model.choosePermission("read")
        let pending = f.controller.managedSettingsApplication
        f.model.update { $0.startWhenZeusOpens.toggle() }
        #expect(f.controller.managedSettingsApplication == pending && f.controller.requests.count == 1)
        #expect(f.controller.lifecycleCalls.isEmpty)
    }
    @Test func editsReplaceAConfirmedWaitingSwitchWithoutAskingAgain() throws {
        let f = try SettingsApplyFixture(); defer { f.cleanup() }
        f.controller.managedStatus = .running(.working)
        f.model.chooseAgent(.codex); f.model.confirm()
        f.model.choosePermission("read")
        #expect(f.model.confirmation == nil && f.controller.managedSettingsApplication?.kind == .newConversation)
        #expect(f.controller.managedSettingsApplication?.configuration.permissionModeID == "read")
        f.model.update { $0.launchPrompt = "First" }
        f.model.update { $0.launchPrompt = "Final" }
        f.model.finishInstructionsEditing()
        #expect(f.model.confirmation == nil && f.controller.managedSettingsApplication?.kind == .newConversation)
        #expect(f.controller.managedSettingsApplication?.configuration.launchPrompt == "Final")
        #expect(f.controller.managedSettingsApplication?.configuration.permissionModeID == "read")
    }
    @Test func unsupportedResumeAndMissingIdentityNeverPromiseSameConversation() throws {
        let f = try SettingsApplyFixture(); defer { f.cleanup() }
        f.controller.supportsInstructions = false
        f.model.update { $0.launchPrompt = "Next conversation only" }
        #expect(f.controller.requests.isEmpty && !f.model.instructionsAreDebouncing)
        #expect(f.model.instructionsCaption.contains("next new conversation"))
        #expect(!f.model.instructionsCaption.contains("keeps the same"))
        f.controller.supportsInstructions = true; f.controller.managedCanResumeSettings = false
        #expect(!f.model.instructionsCaption.contains("keeps the same"))
    }
    @Test func debounceCompletionAndCancellationAreDeterministic() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        let debouncer = ManagedInstructionsDebouncer { await withCheckedContinuation { continuation = $0 } }
        var count = 0
        debouncer.schedule { count += 1 }
        try await eventually { continuation != nil }
        debouncer.cancel(); continuation?.resume(); continuation = nil
        await Task.yield()
        #expect(count == 0)
        debouncer.schedule { count += 10 }
        try await eventually { continuation != nil }
        continuation?.resume(); continuation = nil
        try await eventually { count == 10 }
        debouncer.flush()
        #expect(count == 10)
    }
}
