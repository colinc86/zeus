import Foundation
import Observation
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor @Observable
private final class ManagedUIController: ManagedSessionControlling, ManagedTerminalPresenting {
    var managedStatus: ManagedSessionStatus = .off
    var managedTmuxSessionName: String?
    var managedAttachCommand: String?
    var managedTerminalSocketPath: String?
    var calls: [String] = []
    var installed: Set<AgentKind> = [.claude, .codex, .opencode]
    var missingTmux = false
    var stopsImmediately = true
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        guard installed.contains(agent) else { return [] }
        return [
            .init(id: "ask", title: "Ask", detail: "Asks before commands.", isUnrestricted: false, isDefault: true),
            .init(id: "read", title: "Read only", detail: "Does not change files.", isUnrestricted: false, isDefault: false),
            .init(id: "future-mode", title: "Future full mode", detail: "Runs commands without asking.", isUnrestricted: true, isDefault: false)
        ]
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? {
        if missingTmux { return "Install tmux (brew install tmux)." }
        if !installed.contains(agent) { return "Install \(agent.rawValue)." }
        return nil
    }
    func startManagedSession() { calls.append("start") }
    func stopManagedSession() { calls.append("stop"); if stopsImmediately { managedStatus = .stopped } }
    func restartManagedSession() { calls.append("restart") }
    func startNewManagedConversation() { calls.append("new") }
    func openManagedSessionInTerminal() { calls.append("terminal") }
}

@MainActor private struct ManagedUIFixture {
    let suite: String
    let defaults: UserDefaults
    let settings: AppSettings
    let controller: ManagedUIController
    let model: ManagedAssistantModel
    init(status: ManagedSessionStatus = .off, installed: Set<AgentKind> = [.claude, .codex, .opencode]) throws {
        suite = "zeus-managed-ui-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        controller = ManagedUIController()
        controller.managedStatus = status; controller.installed = installed
        switch status {
        case .starting, .running, .blocked, .restarting: settings.managedLaunchedConfig = settings.managedSession
        default: break
        }
        let controller = controller
        model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor struct ManagedAssistantTests {
    @Test func freshSettingsUseManagedWithoutLaunchingOrFabricatingCheckIn() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        #expect(f.model.enabled && f.model.config.agent == .claude)
        #expect(f.model.config.folder.isEmpty && !f.model.config.startWhenZeusOpens)
        #expect(f.model.config.launchPrompt == ZeusManagedCopy.defaultLaunchPrompt)
        #expect(f.model.selectedPermissionID == "ask")
        #expect(f.model.presentation().detail == "Choose a folder to start.")
        #expect(!f.model.canStart && f.controller.calls.isEmpty)
        #expect(SettingsTab.agent.rawValue == "Assistant")
    }
    @Test func initializationDoesNotWriteManagedConfigurationUntilTheUserEditsIt() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        #expect(f.defaults.data(forKey: "agent.managedSession") == nil)
        let restored = AppSettings(defaults: f.defaults, userDirectory: nil)
        #expect(restored.managedSession == f.settings.managedSession)
        f.model.chooseFolder("/tmp")
        #expect(f.defaults.data(forKey: "agent.managedSession") != nil)
    }
    @Test(arguments: [ManagedSessionStatus.starting, .running(.idle), .blocked(reason: "Trust?"), .failed(reason: "Launch failed"), .restarting(at: Date())])
    func pendingSettingsPreserveThePrimaryRecoveryAction(_ state: ManagedSessionStatus) throws {
        let f = try ManagedUIFixture(status: state); defer { f.cleanup() }
        f.model.chooseFolder("/tmp")
        let actions = f.model.presentation().actions
        switch state {
        case .starting, .running: #expect(actions.first == .restart)
        case .blocked: #expect(actions == [.openInTerminal, .stop])
        case .failed: #expect(actions == [.start, .openInTerminal])
        case .restarting: #expect(actions == [.stop])
        default: break
        }
    }
    @Test(arguments: [ManagedSessionStatus.running(.working), .blocked(reason: "Permission")])
    func pendingAgentAndFolderEditsKeepTheLaunchedIdentityUntilANewConversation(_ status: ManagedSessionStatus) throws {
        let f = try ManagedUIFixture(status: status); defer { f.cleanup() }
        var launched = f.model.config; launched.folder = "/old/folder"
        f.settings.managedSession = launched; f.settings.managedLaunchedConfig = launched
        f.model.chooseAgent(.codex); f.model.chooseFolder("/new/folder")
        #expect(f.model.config.agent == .codex && f.model.config.folder == "/new/folder")
        #expect(f.model.needsRestart && f.model.needsNewConversation && f.controller.calls.isEmpty)
        #expect(f.model.currentConfiguration?.agent == .claude && f.model.currentConfiguration?.folder == "/old/folder")
        switch status {
        case .running:
            #expect(f.model.presentation().detail.contains("Claude Code") && f.model.presentation().detail.contains("/old/folder"))
        case .blocked:
            #expect(f.model.presentation().menuStatus?.contains("Claude Code") == true)
        default: break
        }
        #expect(ConversationView.composerPlaceholder(managed: f.model.currentConfiguration, status: status, assistantLabel: nil) == "Message Claude…")
        f.model.perform(.restart); #expect(f.model.confirmation == .switchConversation)
        f.model.confirm(); #expect(f.controller.calls == ["new"])
        f.controller.managedStatus = .starting
        #expect(ConversationView.composerPlaceholder(managed: f.model.currentConfiguration, status: .starting, assistantLabel: nil) == "Message your assistant…")
        f.controller.managedStatus = .running(.idle)
        #expect(f.model.presentation().detail.contains("Codex") == true)
        #expect(f.model.presentation().detail.contains("/new/folder") == true)
        #expect(ConversationView.composerPlaceholder(managed: f.model.currentConfiguration, status: .running(.idle), assistantLabel: nil) == "Message Codex…")
    }

    @Test func adoptionUsesTheNativeConversationInsteadOfPendingPreferencesWhenLaunchMetadataIsMissing() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle(); f.controller.shutdown()
        let suite = "zeus-adopted-ui-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        var pending = AppSettings.newManagedSession(); pending.agent = .codex; pending.folder = "/new/folder"
        settings.managedSession = pending
        let cards = CardStore(fileURL: f.folder.appendingPathComponent("cards.json"))
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: settings, clock: f.clock,
            socketPath: f.folder.appendingPathComponent("ui.sock").path, ledgerURL: f.folder.appendingPathComponent("deliveries.json"), connectors: [], managedController: f.controller)
        try runtime.start(); defer { runtime.stop() }; try await f.settle()
        let model = ManagedAssistantModel(settings: settings, controller: { runtime })
        #expect(await f.host.commands.count == 1)
        #expect(model.currentConfiguration?.agent == .claude && model.currentConfiguration?.folder == f.folder.path)
        #expect(settings.managedSession == pending && model.needsNewConversation)
        #expect(model.presentation().detail.contains("Claude Code") == true)
        #expect(model.status == .starting)
        #expect(ConversationView.composerPlaceholder(managed: model.currentConfiguration, status: model.status, assistantLabel: nil) == "Message your assistant…")
        #expect(ConversationView.composerPlaceholder(managed: model.currentConfiguration, status: .running(.idle), assistantLabel: nil) == "Message Claude…")
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(restored.managedLaunchedConfig?.agent == .claude && restored.managedLaunchedConfig?.folder == f.folder.path)
    }

    @Test func anActiveAdapterWithoutLaunchIdentityUsesGenericCopy() throws {
        let f = try ManagedUIFixture(status: .running(.unknown)); defer { f.cleanup() }
        f.settings.managedLaunchedConfig = nil
        #expect(f.model.currentConfiguration == nil && f.model.agentName == "Your assistant")
        #expect(ConversationView.composerPlaceholder(managed: f.model.currentConfiguration, status: f.model.status, assistantLabel: nil) == "Message your assistant…")
    }

    @Test func unavailableActionsStayInThePresentationAndTerminalRemainsUsable() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        #expect(f.model.presentation().actions == [.start] && f.model.disabledActions.contains(.start))
        f.model.chooseFolder("/tmp")
        #expect(!f.model.disabledActions.contains(.start))
        f.controller.managedStatus = .failed(reason: "Missing CLI")
        f.controller.managedTmuxSessionName = "zeus"
        f.controller.managedAttachCommand = "tmux attach -t zeus"
        f.controller.missingTmux = true; f.model.refreshAvailability()
        #expect(f.model.disabledActions.contains(.tryAgain) && !f.model.disabledActions.contains(.openInTerminal))
        #expect(f.model.presentation().actions == [.start, .openInTerminal])
    }
    @Test(arguments: [ManagedSessionStatus?.none, .off, .starting, .stopped, .failed(reason: "Missing CLI")])
    func composerDoesNotNameAnUnstartedManagedSession(_ state: ManagedSessionStatus?) {
        let config = AppSettings.newManagedSession()
        #expect(ConversationView.composerPlaceholder(managed: config, status: state, assistantLabel: "Unrelated") == "Message your assistant…")
    }
    @Test func composerNamesRunningManagedAndConnectedOwnSessions() {
        var config = AppSettings.newManagedSession()
        #expect(ConversationView.composerPlaceholder(managed: config, status: .running(.unknown), assistantLabel: nil) == "Message Claude…")
        config.enabled = false
        #expect(ConversationView.composerPlaceholder(managed: config, status: .running(.idle), assistantLabel: "My Codex") == "Message My Codex…")
        #expect(ConversationView.composerPlaceholder(managed: nil, status: nil, assistantLabel: nil) == "Message your assistant…")
    }
    @Test(arguments: [(AgentKind.claude, "Claude"), (.codex, "Codex"), (.opencode, "OpenCode")])
    func ownComposerUsesTheShortAgentNameInsteadOfFolderOrClientName(_ value: (AgentKind, String)) {
        let session = ConnectedSession(id: UUID(), sessionKey: "\(value.0.rawValue):/work/Website#123.456", agent: value.0, cwd: "/work/Website",
            clientName: "Custom assistant · Website", supportsChannel: false, tmuxPane: nil, connectedAt: Date())
        let name = ConversationView.composerAssistantName(session)
        #expect(ConversationView.composerPlaceholder(managed: nil, status: nil, assistantLabel: name) == "Message \(value.1)…")
        #expect(ConversationView.composerAssistantName(nil) == nil)
    }

    @Test func configurationRoundTripsEveryFieldAndRoutingRemainsGetOnlyToRuntime() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.model.chooseFolder("/tmp/My Assistant")
        f.model.chooseAgent(.codex)
        f.model.choosePermission("read")
        f.model.update { $0.launchPrompt = "Custom instructions\nKeep my own setup."; $0.startWhenZeusOpens = false }
        let restored = AppSettings(defaults: f.defaults, userDirectory: nil)
        let routing: any AgentRoutingSettings = restored
        #expect(routing.managedSession == f.settings.managedSession)
        #expect(routing.managedSession?.folder == "/tmp/My Assistant")
        #expect(routing.managedSession?.agent == .codex && routing.managedSession?.permissionModeID == "read")
        #expect(restored.managedAgentInitialized && f.controller.calls.isEmpty)
    }
    @Test func migrationPreservesConnectedAgentAndBadJSONDoesNotAutostartOrOverwriteEvidence() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.defaults.removeObject(forKey: "agent.managedSession")
        f.defaults.set("opencode", forKey: "agent.backend")
        f.defaults.set("opencode:/work#123.456", forKey: "agent.assistantSessionKey")
        let legacy = AppSettings(defaults: f.defaults, userDirectory: nil)
        #expect(legacy.managedSession?.enabled == true && legacy.backend == .opencode)
        #expect(legacy.managedSession?.startWhenZeusOpens == false && legacy.managedSession?.folder.isEmpty == true)
        #expect(legacy.assistantSessionKey == "opencode:/work#123.456")
        let corrupt = Data("broken-json".utf8)
        f.defaults.set(corrupt, forKey: "agent.managedSession")
        let restored = AppSettings(defaults: f.defaults, userDirectory: nil)
        #expect(restored.managedSession?.enabled == false && restored.managedSettingsError != nil)
        #expect(f.defaults.data(forKey: "agent.managedSession") == corrupt)
    }
    @Test func firstInstalledAgentIsSelectedOnceAndMissingTmuxDoesNotDisableInstalledAgent() throws {
        let f = try ManagedUIFixture(installed: [.codex, .opencode]); defer { f.cleanup() }
        #expect(f.model.config.agent == .codex && f.model.selectedPermissionID == "ask")
        f.model.chooseAgent(.opencode)
        f.controller.installed.insert(.claude); f.model.refreshAvailability()
        #expect(f.model.config.agent == .opencode)
        f.controller.missingTmux = true; f.model.refreshAvailability(); f.model.chooseFolder("/tmp")
        #expect(!f.model.canStart && !f.model.permissionModes.isEmpty)
        #expect(f.model.note?.contains("tmux") == true)
        f.model.perform(.start)
        #expect(f.controller.calls.isEmpty)
    }
    @Test func selectingFolderDefaultsAutoStartupOnlyOnFirstSelectionAndNeverLaunches() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.model.chooseFolder("relative"); #expect(f.model.config.folder.isEmpty)
        f.model.chooseFolder("/tmp"); #expect(f.model.config.startWhenZeusOpens && f.model.canStart)
        f.model.update { $0.startWhenZeusOpens = false }
        f.model.chooseFolder("/tmp/Other")
        #expect(!f.model.config.startWhenZeusOpens && f.controller.calls.isEmpty)
    }
    @Test func createFolderUsesControllerResultAndKeepsSelectionWhenCreationFails() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.model.createFolder = { URL(fileURLWithPath: "/tmp/Assistant", isDirectory: true) }
        f.model.createDefaultFolder()
        #expect(f.model.config.folder == "/tmp/Assistant" && f.model.config.startWhenZeusOpens)
        #expect(f.controller.calls.isEmpty)
        f.model.createFolder = { throw CocoaError(.fileWriteNoPermission) }
        f.model.createDefaultFolder()
        #expect(f.model.config.folder == "/tmp/Assistant" && f.model.note?.contains("Couldn't create") == true)
    }
    @Test func permissionChoicesFollowReturnedInventoryAndUnrestrictedNeedsExplicitConfirmation() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        #expect(f.model.permissionModes.map(\.id) == ["ask", "read", "future-mode"])
        f.model.choosePermission("future-mode")
        #expect(f.model.confirmation != nil && f.model.config.permissionModeID == nil)
        f.model.cancelConfirmation(); #expect(f.model.config.permissionModeID == nil)
        f.model.choosePermission("future-mode"); f.model.confirm()
        #expect(f.model.config.permissionModeID == "future-mode")
        f.model.choosePermission("ask"); #expect(f.model.config.permissionModeID == nil)
        f.model.choosePermission("not-a-mode"); #expect(f.model.config.permissionModeID == nil)
        #expect(f.controller.calls.isEmpty)
    }
    @Test func changingAgentCancelsPendingUnrestrictedChoiceAndRestoresNormalDefault() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.model.choosePermission("future-mode")
        f.model.chooseAgent(.codex); f.model.confirm()
        #expect(f.model.confirmation == nil && f.model.config.permissionModeID == nil)
        #expect(f.model.config.agent == .codex)
    }
    @Test(.timeLimit(.minutes(1))) func stopAndSwitchWaitsForControllerAndCanceledSwitchKeepsRunning() async throws {
        let f = try ManagedUIFixture(status: .running(.working)); defer { f.cleanup() }
        f.model.chooseManaged(false); #expect(f.model.confirmation == .switchToOwn)
        f.model.cancelConfirmation(); #expect(f.model.enabled && f.controller.calls.isEmpty)
        f.controller.stopsImmediately = false
        f.model.chooseManaged(false); f.model.confirm()
        #expect(f.model.enabled && f.model.switching && f.controller.calls == ["stop"])
        try #require(f.model.switching)
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = f.model.switching } onChange: {
                Task { @MainActor in continuation.resume() }
            }
            f.controller.managedStatus = .stopped
        }
        #expect(!f.model.enabled && !f.model.switching)
        #expect(AppSettings(defaults: f.defaults, userDirectory: nil).managedSession?.enabled == false)
    }
    @Test(.timeLimit(.minutes(1))) func switchWaitsForPaneReleaseRatherThanEarlyStoppedStatus() async throws {
        let f = try ManagedUIFixture(status: .running(.idle)); defer { f.cleanup() }
        f.controller.managedTmuxSessionName = "zeus-2"; f.controller.stopsImmediately = false
        f.model.chooseManaged(false); f.model.confirm()
        f.controller.managedStatus = .stopped
        #expect(f.model.switching && f.model.enabled)
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = f.model.switching } onChange: {
                Task { @MainActor in continuation.resume() }
            }
            f.controller.managedTmuxSessionName = nil
        }
        #expect(!f.model.switching && !f.model.enabled && f.controller.calls == ["stop"])
    }
    @Test(.timeLimit(.minutes(1))) func stoppingAnAlreadyFailedSessionWaitsForNewTeardownResult() async throws {
        let f = try ManagedUIFixture(status: .failed(reason: "Previous launch failure")); defer { f.cleanup() }
        f.controller.managedTmuxSessionName = "zeus"; f.controller.stopsImmediately = false
        f.model.chooseManaged(false); f.model.confirm()
        #expect(f.model.enabled && f.model.switching && f.model.actionError == nil)
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = f.model.switching } onChange: {
                Task { @MainActor in continuation.resume() }
            }
            f.controller.managedStatus = .stopped
            f.controller.managedTmuxSessionName = nil
        }
        #expect(!f.model.enabled && !f.model.switching)
    }
    @Test(.timeLimit(.minutes(1))) func failedStopKeepsManagedRoutingEnabledAndShowsReason() async throws {
        let f = try ManagedUIFixture(status: .blocked(reason: "Trust folder?")); defer { f.cleanup() }
        f.controller.stopsImmediately = false
        f.model.chooseManaged(false); f.model.confirm()
        try #require(f.model.switching)
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = f.model.switching } onChange: {
                Task { @MainActor in continuation.resume() }
            }
            f.controller.managedStatus = .failed(reason: "Ownership changed")
        }
        #expect(f.model.enabled && !f.model.switching)
        #expect(f.model.note?.contains("Ownership changed") == true)
    }
    @Test func switchingBackNeverStartsAndRetainsAdvancedSettings() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.settings.assistantSessionKey = "codex:/saved#10.20"; f.settings.tmuxTarget = "%42"
        f.model.chooseFolder("/tmp"); f.model.chooseManaged(false); f.model.chooseManaged(true)
        #expect(f.model.enabled && !f.model.config.startWhenZeusOpens)
        #expect(f.controller.calls.isEmpty && f.settings.assistantSessionKey == "codex:/saved#10.20" && f.settings.tmuxTarget == "%42")
    }
    @Test func instructionsDoNotRestartAndNewConversationRequiresConfirm() throws {
        let f = try ManagedUIFixture(status: .running(.idle)); defer { f.cleanup() }
        f.model.chooseFolder("/tmp")
        f.model.update { $0.launchPrompt = "Edited" }
        #expect(f.controller.calls.isEmpty)
        f.model.confirmation = .newConversation; f.model.cancelConfirmation()
        #expect(f.controller.calls.isEmpty)
        f.model.confirmation = .newConversation; f.model.confirm()
        #expect(f.controller.calls == ["new"])
    }
    @Test func permissionsRestartSameConversationButAgentOrFolderChangeConfirmsFreshContext() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.model.chooseFolder("/tmp"); f.model.perform(.start)
        f.controller.managedStatus = .running(.idle)
        f.model.choosePermission("read")
        #expect(f.model.needsRestart && f.model.presentation().actions.first == .restart)
        f.model.perform(.restart)
        #expect(f.controller.calls == ["start", "restart"])
        #expect(!f.model.needsRestart)
        f.model.chooseFolder("/tmp/Other"); f.model.perform(.restart)
        #expect(f.model.confirmation == .switchConversation && f.controller.calls.count == 2)
        f.model.cancelConfirmation(); #expect(f.model.needsRestart)
        f.model.perform(.restart); f.model.confirm()
        #expect(f.controller.calls == ["start", "restart", "new"])
    }
    @Test func unappliedAgentAndFolderChangesRemainVisibleAfterRelaunch() throws {
        let f = try ManagedUIFixture(); defer { f.cleanup() }
        f.model.chooseFolder("/tmp"); f.model.perform(.start)
        f.controller.managedStatus = .running(.idle)
        f.model.chooseAgent(.codex)
        let restored = AppSettings(defaults: f.defaults, userDirectory: nil)
        let controller = f.controller
        let model = ManagedAssistantModel(settings: restored, controller: { controller })
        model.refreshAvailability()
        #expect(model.needsRestart && model.needsNewConversation)
        model.perform(.restart)
        #expect(model.confirmation == .switchConversation && f.controller.calls == ["start"])
    }
    @Test func terminalActionUsesControllerAttachCommandAndDoesNotModifyConfiguration() throws {
        let f = try ManagedUIFixture(status: .blocked(reason: "Sign in")); defer { f.cleanup() }
        f.controller.managedTmuxSessionName = "zeus-2"
        f.controller.managedAttachCommand = "tmux -S '/tmp/my socket' attach -t '=zeus-2'"
        let before = f.settings.managedSession
        f.controller.managedTerminalSocketPath = "/tmp/my socket"
        #expect(f.model.attachCommand == "tmux -S '/tmp/my socket' attach -t zeus-2")
        f.model.perform(.openInTerminal)
        #expect(f.controller.calls == ["terminal"] && f.settings.managedSession == before)
        #expect(f.model.menuActions == [.openInTerminal, .restart, .stop])
    }
    @Test(arguments: [ManagedSessionStatus.off, .starting, .running(.idle), .running(.working), .running(.unknown), .blocked(reason: "Trust?"), .stopped, .restarting(at: Date(timeIntervalSince1970: 50)), .failed(reason: "CLI missing")])
    func everyStatusMapsToDesignerPresentationWithAlertPriority(_ status: ManagedSessionStatus) throws {
        let f = try ManagedUIFixture(status: status); defer { f.cleanup() }
        let expected = ZeusManagedPresentation.make(ManagedAssistantModel.designState(status), agent: "Claude Code", folder: "", session: nil, now: Date(timeIntervalSince1970: 47))
        let actual = f.model.presentation(now: Date(timeIntervalSince1970: 47))
        #expect(actual.title == expected.title && actual.tone == expected.tone && actual.menuStatus == expected.menuStatus)
        #expect(f.model.menuStatus(usual: "2 new messages", unread: 2) == (expected.menuStatus ?? expected.detail))
        #expect(f.model.menuStatus(usual: "Ready to talk", unread: 0) == (expected.menuStatus ?? expected.detail))
        switch status {
        case .off, .stopped: #expect(f.model.menuActions == [.start])
        case .failed: #expect(f.model.menuActions == [.start])
        case .restarting: #expect(f.model.menuActions == [.stop])
        default: #expect(f.model.menuActions == [.restart, .stop])
        }
        #expect(f.model.isMenuAlert == (expected.tone == .attention))
    }
}
