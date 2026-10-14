import Foundation
import Darwin
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Observable private final class ConnectOwnController: ManagedSessionControlling, RetainedManagedSessionPresenting {
    var managedStatus: ManagedSessionStatus = .running(.idle)
    var managedTmuxSessionName: String? = "zeus"
    var managedAttachCommand: String? = "tmux attach -t zeus"
    var retainedManagedSession: RetainedManagedSession? = .init(attachCommand: "tmux attach -t zeus")
    var stops = 0
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] { [] }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { nil }
    func startManagedSession() {}
    func stopManagedSession() { stops += 1 }
    func restartManagedSession() {}
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
}

@MainActor struct ConnectOwnModeTests {
    @Test func savedLeaseNoticeSurvivesReopenButDoesNotClaimAReusedPIDOrRouteToIt() throws {
        let suite = "zeus-cy1-lease-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-cy1-lease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        child.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        var info = proc_bsdinfo()
        try #require(proc_pidinfo(child.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0)
        let start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = .init(enabled: false, folder: root.path, agent: .claude, launchPrompt: "Fixture", startWhenZeusOpens: false)
        settings.assistantSessionKey = "codex:/own#\(child.processIdentifier).\(start)"
        let controller = ManagedSessionController(configuration: { settings.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: root.appendingPathComponent("zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: .init(tmux: nil, agents: [:]), environment: ["HOME": root.path], isolatedSocket: root.appendingPathComponent("tmux.sock").path)
        var record = ManagedSessionRecord()
        record.name = "zeus-2"
        record.pane = .init(name: "zeus-2", id: "%0", socket: root.appendingPathComponent("tmux.sock").path,
            serverPID: 1, sessionNumber: "0", pid: Int(child.processIdentifier), startTime: start, dead: false)
        try controller.store.save(record)
        let runtime = ZeusRuntime(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), status: FakeStatus(), characters: FakeCharacters(),
            routing: settings, socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("ledger.json"), managedController: controller)
        let model = ManagedAssistantModel(settings: settings, controller: { runtime })
        #expect(controller.record == nil && model.retainedSessionNotice?.contains("zeus-2") == true)
        #expect(model.retainedSessionNotice?.contains("-S") == true, "The actual private socket/collision name must be attachable")
        #expect(runtime.assistantTarget == settings.assistantSessionKey, "A retained lease is not the assistant target")
        record.pane?.startTime = start + 1; try controller.store.save(record); model.refreshRetainedSession()
        #expect(model.retainedSessionNotice == nil, "Never identify a new PID lifetime as the old agent")
        record.pane?.startTime = start; try controller.store.save(record); model.refreshRetainedSession()
        #expect(model.retainedSessionNotice != nil)
        child.terminate(); child.waitUntilExit(); model.refreshRetainedSession()
        #expect(model.retainedSessionNotice == nil)
    }

    @Test func keepRunningSwitchesAndRetainsTheNoticeAfterManagedStatusTurnsOffUntilExit() throws {
        let suite = "zeus-cy1-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let controller = ConnectOwnController(), model = ManagedAssistantModel(settings: settings, controller: { controller })
        settings.assistantSessionKey = "codex:/own#10.20"
        model.chooseManaged(false)
        #expect(model.enabled && model.confirmation == .switchToOwn && controller.stops == 0)
        model.keepRunningAndConnectOwn()
        #expect(!model.enabled && model.confirmation == nil && controller.stops == 0)
        #expect(settings.assistantSessionKey == "codex:/own#10.20")
        #expect(model.retainedSessionNotice == "Your Zeus-run agent is still running in tmux (tmux attach -t zeus)")
        controller.managedStatus = .off; controller.managedTmuxSessionName = nil; controller.managedAttachCommand = nil
        model.refreshRetainedSession()
        #expect(model.retainedSessionNotice != nil, "Detach's Off status isn't a process exit")
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        let reopened = ManagedAssistantModel(settings: restored, controller: { controller })
        #expect(reopened.retainedSessionNotice == model.retainedSessionNotice)
        controller.retainedManagedSession = nil
        model.refreshRetainedSession()
        #expect(model.retainedSessionNotice == nil && controller.stops == 0)
    }

    @Test func stopKeepsManagedModeUntilTheOwnedPaneIsReleased() async throws {
        let suite = "zeus-cy1-stop-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let controller = ConnectOwnController(), model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.chooseManaged(false); model.confirm()
        #expect(controller.stops == 1 && model.enabled && model.switching && model.retainedSessionNotice == nil)
        controller.managedStatus = .stopped
        #expect(model.enabled && model.switching)
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = model.switching } onChange: { Task { @MainActor in continuation.resume() } }
            controller.retainedManagedSession = nil; controller.managedTmuxSessionName = nil
        }
        #expect(!model.enabled && !model.switching && model.retainedSessionNotice == nil)
    }

    @Test func switchingBackHidesTheNoticeAndDoesNotStopTheSurvivingAgent() throws {
        let suite = "zeus-cy1-back-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let controller = ConnectOwnController(), model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.chooseManaged(false); model.keepRunningAndConnectOwn()
        model.chooseManaged(true)
        #expect(model.enabled && model.retainedSessionNotice == nil && controller.stops == 0)
        #expect(!model.config.startWhenZeusOpens)
        model.keepRunningAndConnectOwn()
        #expect(model.enabled, "Only the actual Stop/Keep Running confirmation can detach")
    }
}
