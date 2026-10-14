import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class R3aManagedController: ManagedSessionControlling {
    var managedStatus: ManagedSessionStatus = .off
    var managedTmuxSessionName: String? { nil }
    var managedAttachCommand: String? { nil }
    var installed: Set<AgentKind> = [.claude, .codex, .opencode]
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        installed.contains(agent) ? [.init(id: "ask", title: "Ask", detail: "Asks", isUnrestricted: false, isDefault: true)] : []
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { installed.contains(agent) ? nil : "Install the agent." }
    func startManagedSession() {}
    func stopManagedSession() {}
    func restartManagedSession() {}
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
}

@MainActor struct R3aSettingsTests {
    private func defaults() throws -> (String, UserDefaults) {
        let name = "zeus-r3a-settings-\(UUID())"
        return (name, try #require(UserDefaults(suiteName: name)))
    }
    @Test func managedOnboardingShowsOnceWithoutInventingAConversationMessageOrChangingTheMode() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(settings.consumeManagedOnboarding(hasHistory: false, isHidden: false))
        #expect(settings.hasShownWelcome && settings.managedSession?.enabled == true)
        #expect(!settings.consumeManagedOnboarding(hasHistory: false, isHidden: false))
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(restored.managedSession?.enabled == true && restored.managedSession?.folder.isEmpty == true)
        #expect(!restored.consumeManagedOnboarding(hasHistory: false, isHidden: false))
    }
    @Test func firstRunDoesNotStealAnExistingHistoryOrOverrideExplicitHiding() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(!settings.consumeManagedOnboarding(hasHistory: true, isHidden: false))
        #expect(!settings.consumeManagedOnboarding(hasHistory: false, isHidden: true))
        #expect(!settings.hasShownWelcome)
    }
    @Test func availabilityPreservesSavedAgentAndPermissionWithoutAMigrationFlag() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        var config = AppSettings.newManagedSession(); config.agent = .opencode; config.permissionModeID = "deny"
        let original = try JSONEncoder().encode(config); defaults.set(original, forKey: "agent.managedSession")
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let controller = R3aManagedController()
        let model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
        #expect(settings.managedSession == config && settings.managedAgentInitialized)
        #expect(defaults.data(forKey: "agent.managedSession") == original)
    }
    @Test(arguments: [true, false]) func malformedPreferencesSurvivePassiveAvailabilityRefresh(dataValue: Bool) throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let bad = Data("broken".utf8)
        if dataValue { defaults.set(bad, forKey: "agent.managedSession") } else { defaults.set("broken", forKey: "agent.managedSession") }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let controller = R3aManagedController(); controller.installed = [.codex]
        let model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
        #expect(settings.managedSettingsError != nil && settings.managedSession?.enabled == false)
        if dataValue { #expect(defaults.data(forKey: "agent.managedSession") == bad) }
        else { #expect(defaults.string(forKey: "agent.managedSession") == "broken") }
        #expect(!settings.consumeManagedOnboarding(hasHistory: false, isHidden: false))
        model.chooseManaged(true); model.chooseAgent(.codex)
        #expect(settings.managedSettingsError == nil && settings.managedSession?.agent == .codex)
    }
    @Test func onboardingStillChoosesFirstInstalledAgentWhenItsPanelWasOpenedBeforeRuntimeStartup() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(settings.consumeManagedOnboarding(hasHistory: false, isHidden: false))
        let controller = R3aManagedController(); controller.installed = [.codex]
        let model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
        #expect(settings.managedSession?.agent == .codex)
    }
    @Test func explicitOfflineSelectionSurvivesStartupAndTransientDisconnectionUntilDeathIsProven() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.assistantSessionKey = "claude:/work#123.456"
        settings.reconcileAssistantSession(with: [], isDead: { _ in false })
        #expect(settings.assistantSessionKey == "claude:/work#123.456" && settings.assistantSessionNotice == nil)
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        restored.reconcileAssistantSession(with: [], isDead: { _ in false })
        #expect(restored.assistantSessionKey == settings.assistantSessionKey)
        restored.reconcileAssistantSession(with: [], isDead: { _ in true })
        #expect(restored.assistantSessionKey == nil && restored.assistantSessionNotice != nil)
        settings.assistantSessionKey = "legacy:unknown"
        settings.reconcileAssistantSession(with: [])
        #expect(settings.assistantSessionKey == "legacy:unknown")
    }
    @Test func realParentLifetimeRemainsPinnedUntilItsProcessExits() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run(); defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        var info = proc_bsdinfo()
        try #require(proc_pidinfo(child.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0)
        let start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.assistantSessionKey = "claude:/fixture#\(child.processIdentifier).\(start)"
        settings.reconcileAssistantSession(with: [])
        #expect(settings.assistantSessionKey != nil)
        child.terminate(); child.waitUntilExit()
        settings.reconcileAssistantSession(with: [])
        #expect(settings.assistantSessionKey == nil)
    }
    @Test func paneAndNamespaceRoundTripTogetherAndChangingDestinationsClearsTheOverride() throws {
        let (name, defaults) = try defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.setTmuxTarget("%0", socketPath: "/tmp/server-A.sock")
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(restored.tmuxTarget == "%0" && restored.tmuxTargetSocketPath == AppSettings.normalizedTmuxSocket("/tmp/server-A.sock"))
        restored.revalidateTmuxTarget(socketPath: nil) // An offline bridge is unknown, not a different server.
        #expect(restored.tmuxTarget == "%0")
        restored.revalidateTmuxTarget(socketPath: "/tmp/server-B.sock")
        #expect(restored.tmuxTarget == nil && restored.tmuxTargetSocketPath == nil)
        settings.assistantSessionKey = "claude:/A#10.20"
        settings.setTmuxTarget("%0", socketPath: "/tmp/server-A.sock")
        settings.assistantSessionKey = "claude:/B#11.21"
        #expect(settings.tmuxTarget == nil && settings.tmuxTargetSocketPath == nil)
        settings.setTmuxTarget("%0", socketPath: nil)
        #expect(settings.tmuxTarget == nil)
    }
}
