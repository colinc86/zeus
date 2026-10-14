import Foundation
import Observation
import SQLite3
import Testing
import ZeusProtocol
@testable import Zeus

actor FakeManagedHost: ManagedSessionHosting {
    var panes: [String: ManagedPane] = [:]
    var owners: [String: String] = [:]
    var commands: [ManagedLaunchCommand] = []
    var creates: [String] = []
    var stops = 0
    var collisionOnce = false
    var snapshot = ManagedPaneSnapshot(screen: "", inputMetadata: "")
    var captures: [String] = []
    var promptAnswers: [String] = []
    var holdPromptAnswer = false
    private var promptContinuation: CheckedContinuation<Void, Never>?
    var awaitingPromptAnswer: Bool { promptContinuation != nil }
    func holdAnswer() { holdPromptAnswer = true }
    func releaseAnswer() { holdPromptAnswer = false; promptContinuation?.resume(); promptContinuation = nil }
    func answerPrompt(_ pane: ManagedPane, owner: String, agent: AgentKind, scope: String,
                      fingerprint: String, optionID: String,
                      stillAllowed: @MainActor @Sendable () -> Bool) async throws -> ManagedPromptAnswerResult {
        if holdPromptAnswer { await withCheckedContinuation { promptContinuation = $0 } }
        guard let current = try inspect(name: pane.name, owner: owner, pane: pane), current == pane,
              let prompt = ManagedPromptParser.parse(snapshot, agent: agent, scope: scope), prompt.fingerprint == fingerprint,
              let option = prompt.options.first(where: { $0.id == optionID }), await stillAllowed() else { return .changed }
        promptAnswers.append(optionID)
        snapshot = .init(screen: "Working · esc to interrupt", inputMetadata: "0|0|120|0|0")
        return .answered(optionID: option.id, label: option.label)
    }
    func capture(_ pane: ManagedPane, owner: String) throws -> ManagedPaneSnapshot {
        guard try inspect(name: pane.name, owner: owner, pane: pane) != nil else { throw ManagedSessionError.ownershipChanged }
        captures.append(pane.id); return snapshot
    }
    func setSnapshot(_ value: ManagedPaneSnapshot) { snapshot = value }
    func sessions() -> [ManagedTmuxSession] { panes.keys.map { .init(name: $0, owner: owners[$0] ?? "") } }
    func inspect(name: String, owner: String, pane: ManagedPane?) throws -> ManagedPane? {
        guard let value = panes[name] else { return nil }
        guard owners[name] == owner, pane == nil || pane?.id == value.id else { throw ManagedSessionError.ownershipChanged }
        return value
    }
    func create(name: String, owner: String, folder: String) throws -> ManagedPane {
        if collisionOnce { collisionOnce = false; throw ManagedSessionError.collision }
        guard panes[name] == nil else { throw ManagedSessionError.collision }
        creates.append(name)
        let value = ManagedPane(name: name, id: "%\(panes.count)", socket: "/tmp/test-owned.sock", serverPID: 1, sessionNumber: "0", pid: 100, startTime: 1000, dead: false)
        panes[name] = value; owners[name] = owner; return value
    }
    func launch(_ pane: ManagedPane, owner: String, command: ManagedLaunchCommand, folder: String) throws -> ManagedPane {
        guard var value = try inspect(name: pane.name, owner: owner, pane: pane) else { throw ManagedSessionError.ownershipChanged }
        commands.append(command); value.pid += 1; value.startTime += 100; value.dead = false; value.exitStatus = nil; value.signal = nil
        panes[pane.name] = value; return value
    }
    func requestExit(_ pane: ManagedPane, owner: String) throws {
        guard try inspect(name: pane.name, owner: owner, pane: pane) != nil else { return }
        die(name: pane.name, status: 0)
    }
    func removePane(_ pane: ManagedPane, owner: String) throws {
        guard try inspect(name: pane.name, owner: owner, pane: pane) != nil else { return }
        stops += 1; panes.removeValue(forKey: pane.name); owners.removeValue(forKey: pane.name)
    }
    func die(name: String = "zeus", status: Int? = nil, signal: String? = "SIGKILL") {
        panes[name]?.dead = true; panes[name]?.exitStatus = status; panes[name]?.signal = status == 0 ? nil : signal
    }
    func occupy(_ name: String) { panes[name] = .init(name: name, id: "%99", socket: "/tmp/test-owned.sock", serverPID: 1, sessionNumber: "0", pid: 99, startTime: 99, dead: false); owners[name] = "user" }
    func changeOwner(_ name: String) { owners[name] = "user" }
    func collide() { collisionOnce = true }
}
actor FakeManagedFinder: ManagedConversationFinding {
    var id: String? = UUID().uuidString
    func nativeID(for conversation: ManagedConversation, environment: [String: String]) -> String? { id }
    func setID(_ value: String?) { id = value }
}
@MainActor @Observable
final class ManagedConfigBox { var value: ManagedSessionConfig? }

@MainActor
final class FakeManagedTerminal: ManagedTerminalOpening {
    var files: [URL] = []
    func open(commandFile: URL) { files.append(commandFile) }
}

@MainActor
struct ManagedFixture {
    let folder: URL
    let config = ManagedConfigBox()
    let host = FakeManagedHost()
    let finder = FakeManagedFinder()
    let clock = TestRuntimeClock()
    let controller: ManagedSessionController
    let terminal = FakeManagedTerminal()
    init(agent: AgentKind = .claude, auto: Bool = true, folder: URL? = nil) throws {
        self.folder = folder ?? URL(fileURLWithPath: "/tmp/mctrl_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        config.value = .init(enabled: true, folder: self.folder.path, agent: agent, launchPrompt: "Original instructions '$()'\nSecond line", startWhenZeusOpens: auto)
        let binary = URL(fileURLWithPath: "/bin/cat")
        controller = .init(configuration: { [config] in config.value }, stateURL: self.folder.appendingPathComponent("state.json"), bridge: binary,
            bridgeSocket: self.folder.appendingPathComponent("bridge.sock").path, executables: .init(tmux: binary, agents: [.claude: binary, .codex: binary, .opencode: binary]),
            hosting: host, finder: finder, environment: ["HOME": self.folder.path, "PATH": "/usr/bin:/bin"], clock: clock, terminalOpener: terminal)
    }
    func settle() async throws { try await eventually { !controller.isBusy } }
    func connectOwned() throws {
        guard let pane = controller.record?.pane, let conversation = controller.record?.conversation else { throw ManagedSessionError.invalidState }
        controller.considerSessions([.init(id: UUID(), sessionKey: "\(conversation.agent.rawValue):\(conversation.folder)#\(pane.pid).\(pane.startTime)", agent: conversation.agent, cwd: conversation.folder, clientName: "Owned", supportsChannel: false, tmuxPane: pane.id, connectedAt: clock.now, tmuxSocketPath: pane.socket)])
    }
    func cleanup() { controller.shutdown(); try? FileManager.default.removeItem(at: folder) }
}

@MainActor
struct ManagedSessionTests {
    @Test func requirementsAndEveryPermissionChoiceIncludesExactUnrestrictedFlags() throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        #expect(f.controller.managedRequirementsProblem(for: .claude) == nil)
        for agent in [AgentKind.claude, .codex, .opencode] {
            let modes = f.controller.permissionModes(for: agent)
            #expect(modes.first?.isDefault == true)
            #expect(modes.filter(\.isDefault).count == 1)
            #expect(Set(modes.map(\.id)).count == modes.count)
            #expect(modes.contains { $0.isUnrestricted })
        }
        #expect(f.controller.permissionModes(for: .other).isEmpty)
        #expect(ManagedAgentLaunch.policies(for: .claude).last?.arguments == ["--dangerously-skip-permissions"])
        #expect(ManagedAgentLaunch.policies(for: .codex).last?.arguments == ["--dangerously-bypass-approvals-and-sandbox"])
        #expect(ManagedAgentLaunch.policies(for: .opencode).last?.arguments == ["--auto"])
        #expect(f.controller.permissionModes(for: .codex).map(\.title) == ["Ask when needed", "Read only", "Approve for me", "Full access", "YOLO"])
        #expect(f.controller.permissionModes(for: .codex).filter(\.isUnrestricted).map(\.id) == ["yolo"])
        for agent in [AgentKind.claude, .codex, .opencode] {
            #expect(f.controller.permissionModes(for: agent).allSatisfy { !$0.title.contains("--") && !$0.detail.contains("--") })
        }
        let missing = ManagedSessionController(configuration: { nil }, stateURL: f.folder.appendingPathComponent("missing"), bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: "unused", executables: .init(agents: [:]))
        #expect(missing.permissionModes(for: .claude).isEmpty)
        #expect(missing.managedRequirementsProblem(for: .codex)?.contains("tmux") == true)
        #expect(missing.managedRequirementsProblem(for: .codex)?.contains("Codex") == true)
    }

    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func launchOnlyInjectionPreservesUserSetupAndResumeDoesNotReplay(agent: AgentKind) async throws {
        let f = try ManagedFixture(agent: agent); defer { f.cleanup() }
        if agent == .opencode { await f.finder.setID("ses_testContext") }
        f.controller.activate(); try await f.settle()
        #expect(f.controller.managedStatus == .starting)
        #expect(f.controller.record?.conversation?.nativeID != nil)
        let first = try #require(await f.host.commands.first)
        #expect(!first.arguments.contains("--strict-mcp-config"))
        #expect(!first.arguments.contains("--setting-sources"))
        #expect(!first.arguments.contains("--pure"))
        let initial = try #require(f.controller.record?.conversation?.firstMessage)
        #expect(first.arguments.contains(initial))
        let context = f.controller.record?.conversation?.nativeID
        f.config.value?.launchPrompt = "Changed only for next conversation"
        f.controller.restartManagedSession(); try await f.settle()
        #expect(f.controller.record?.conversation?.nativeID == context)
        let second = try #require(await f.host.commands.last)
        #expect(!second.arguments.contains(initial))
        #expect(second.arguments.contains(context ?? "missing"))
        #expect(f.controller.record?.conversation?.launchPrompt.contains("Original instructions") == true)
        #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent(".mcp.json").path))
        if agent == .codex {
            #expect(second.arguments.contains("--no-daemon"))
            let table = try #require(second.arguments.first { $0.hasPrefix("mcp_servers.zeus=") })
            #expect(table.contains("TMUX_PANE") && table.contains("/tmp/test-owned.sock"))
        }
        f.controller.startNewManagedConversation(); try await f.settle()
        #expect(f.controller.record?.conversation?.launchPrompt == "Changed only for next conversation")
        #expect(f.controller.record?.conversation?.firstMessage != initial)
    }

    @Test func collisionNeverTouchesUsersSessionAndDoubleStartAdopts() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        await f.host.occupy("zeus"); await f.host.occupy("zeus-2")
        f.controller.activate(); f.controller.startManagedSession(); try await f.settle()
        #expect(f.controller.managedTmuxSessionName == "zeus-3")
        #expect(await f.host.commands.count == 1)
        #expect(await f.host.owners["zeus"] == "user")
        f.controller.stopManagedSession(); try await f.settle()
        #expect(f.controller.managedStatus == .stopped)
        #expect(await f.host.panes["zeus"] != nil)
        #expect(await f.host.stops == 1)
    }

    @Test func cleanExitStopsWhileSignalsUseExactBackoffAndCrashLimit() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        await f.host.die(status: 0); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .stopped)
        #expect(f.controller.sessionKey == nil)
        f.clock.advance(60); try await f.settle()
        #expect(await f.host.commands.count == 1)
        f.controller.startManagedSession(); try await f.settle()
        for delay in [TimeInterval(2), 10, 60, 60, 60] {
            await f.host.die(); f.controller.refresh(); try await f.settle()
            let expected = f.clock.now.addingTimeInterval(delay)
            #expect(f.controller.managedStatus == .restarting(at: expected))
            // Unrelated routing/config notifications must not bypass this deadline.
            f.controller.configurationChanged(); try await f.settle()
            #expect(f.controller.managedStatus == .restarting(at: expected))
            let count = await f.host.commands.count
            f.clock.advance(delay - 0.1); await Task.yield()
            #expect(await f.host.commands.count == count)
            f.clock.advance(0.1)
            try await eventually { f.controller.managedStatus == .starting }
            try await f.settle()
        }
        await f.host.die(); f.controller.refresh(); try await f.settle()
        guard case .failed(let reason) = f.controller.managedStatus else { Issue.record("Crash loop didn't fail"); return }
        #expect(reason.contains("5 times in 10 minutes"))
        #expect(f.controller.record?.restarts.count == 5)
    }

    @Test func relaunchAdoptsWithoutSpawningAndShutdownLeavesAgentAlive() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        try f.connectOwned()
        let key = f.controller.sessionKey
        f.controller.shutdown()
        #expect(await f.host.stops == 0)
        f.config.value?.startWhenZeusOpens = false
        let adopted = ManagedSessionController(configuration: { f.config.value }, stateURL: f.folder.appendingPathComponent("state.json"), bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: "unused", executables: f.controller.executables, hosting: f.host, finder: f.finder, clock: f.clock)
        defer { adopted.shutdown() }
        adopted.activate(); try await eventually { !adopted.isBusy }
        #expect(adopted.sessionKey == key)
        #expect(await f.host.commands.count == 1)
    }

    @Test func missingNativeIdentityNeverRestartsWithNewContext() async throws {
        let f = try ManagedFixture(agent: .codex); defer { f.cleanup() }
        await f.finder.setID(nil)
        f.controller.activate(); try await f.settle()
        await f.host.die(); f.controller.refresh(); try await f.settle()
        f.clock.advance(2)
        try await eventually { if case .failed = f.controller.managedStatus { return true }; return false }
        #expect(await f.host.commands.count == 1)
        #expect(f.controller.record?.conversation?.didLaunch == true)
    }

    @Test func changedOwnerStopsAndCorruptStateIsLeftIntact() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        await f.host.changeOwner("zeus")
        f.controller.stopManagedSession(); try await f.settle()
        #expect(await f.host.stops == 0)
        guard case .failed = f.controller.managedStatus else { Issue.record("Ownership failure missing"); return }
        let path = f.folder.appendingPathComponent("corrupt.json"); let data = Data("not-json".utf8); try data.write(to: path)
        let other = ManagedSessionController(configuration: { f.config.value }, stateURL: path, bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: "unused", executables: f.controller.executables, hosting: f.host)
        defer { other.shutdown() }
        other.activate(); try await eventually { !other.isBusy }
        #expect(try Data(contentsOf: path) == data)
        #expect(await f.host.commands.count == 1)
    }

    @Test func disabledOrManualStartupAndInvalidConfigNeverLaunch() async throws {
        let f = try ManagedFixture(auto: false); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        #expect(f.controller.managedStatus == .off)
        #expect(await f.host.commands.isEmpty)
        f.config.value?.folder = "relative"
        f.controller.startManagedSession(); try await f.settle()
        guard case .failed = f.controller.managedStatus else { Issue.record("Bad folder didn't fail"); return }
        #expect(await f.host.commands.isEmpty)
        f.config.value?.enabled = false; f.controller.configurationChanged()
        #expect(f.controller.managedStatus == .off)
    }

    @Test func openTerminalUsesActualSocketAndPrivateScriptWithoutShellInjection() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        f.controller.openManagedSessionInTerminal(); try await f.settle()
        let file = try #require(f.terminal.files.first)
        #expect(file.pathExtension == "command")
        let script = try String(contentsOf: file, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\nexec "))
        #expect(script.contains("/tmp/test-owned.sock"))
        let paneID = try #require(f.controller.record?.pane?.id)
        #expect(script.contains("attach -t " + ManagedSessionController.shellQuote(paneID)))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(f.controller.managedAttachCommand?.contains("-u TMUX -u TMUX_PANE") == true)
        #expect(ManagedSessionController.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func runtimePinsOnlyOwnedProcessAndQueuesInsteadOfSelectingAnotherAssistant() async throws {
        let f = try ManagedFixture(auto: false); defer { f.cleanup() }
        let r = try RuntimeFixture(); defer { r.stop() }
        let runtime = ZeusRuntime(cards: r.cards, status: r.status, characters: r.characters, routing: r.routing, clock: r.clock,
            socketPath: f.folder.appendingPathComponent("runtime.sock").path, ledgerURL: f.folder.appendingPathComponent("deliveries.json"), connectors: [r.connector], targetIsDead: { _ in false }, managedController: f.controller)
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(.init(id: UUID(), sessionKey: "claude:/unrelated#123.100", agent: .claude, cwd: "/unrelated", clientName: nil, supportsChannel: true, tmuxPane: "%9", connectedAt: r.clock.now))
        try await f.settle()
        #expect(runtime.assistantTarget == nil)
        #expect(await runtime.sendUserMessage("wait for owned agent") == .queued(reason: "Claude Code isn't running. Start it to send this."))
        f.controller.startManagedSession(); try await f.settle()
        #expect(runtime.assistantTarget == nil) // A process alone cannot claim a cwd-based bridge key.
        let pane = try #require(f.controller.record?.pane)
        let conversation = try #require(f.controller.record?.conversation)
        let owned = "\(conversation.agent.rawValue):\(conversation.folder)#\(pane.pid).\(pane.startTime)"
        runtime.registerSession(.init(id: UUID(), sessionKey: owned, agent: conversation.agent, cwd: conversation.folder, clientName: "Owned", supportsChannel: false, tmuxPane: pane.id, connectedAt: r.clock.now, tmuxSocketPath: pane.socket))
        #expect(runtime.assistantTarget == owned)
        #expect(runtime.assistantTarget != "claude:/unrelated#123.100")
    }
}

@MainActor
extension ManagedSessionTests {
    @Test func newConversationCanRecoverAfterOwnershipChangeWithoutKillingForeignPane() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        let old = f.controller.record?.conversation?.nativeID
        await f.host.changeOwner("zeus")
        f.controller.startNewManagedConversation(); try await f.settle()
        #expect(f.controller.managedStatus == .starting)
        #expect(f.controller.managedTmuxSessionName == "zeus-2")
        #expect(f.controller.record?.conversation?.nativeID != old)
        #expect(await f.host.owners["zeus"] == "user")
        #expect(await f.host.stops == 0)
    }

    @Test func launchIntentAfterInterruptedRespawnAdoptsNewProcessInsteadOfDuplicatingIt() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        let live = try #require(f.controller.record?.pane)
        var pending = try #require(f.controller.record)
        pending.launchPending = true; pending.pendingWasFresh = true
        pending.pane?.pid -= 1; pending.pane?.startTime -= 100
        try ManagedSessionStore(url: f.folder.appendingPathComponent("state.json")).save(pending)
        f.controller.shutdown()
        let adopted = ManagedSessionController(configuration: { f.config.value }, stateURL: f.folder.appendingPathComponent("state.json"), bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: "unused", executables: f.controller.executables, hosting: f.host, clock: f.clock)
        defer { adopted.shutdown() }
        adopted.activate(); try await eventually { adopted.managedStatus == .starting && !adopted.isBusy }
        #expect(adopted.record?.pane?.pid == live.pid)
        #expect(adopted.record?.launchPending == false)
        #expect(await f.host.commands.count == 1)
    }

    @Test func requirementsRedetectNewLocalExecutableWithoutAppRelaunch() throws {
        let folder = URL(fileURLWithPath: "/tmp/mdetect_" + UUID().uuidString.prefix(8))
        let bin = folder.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ManagedSessionController(configuration: { nil }, stateURL: folder.appendingPathComponent("state.json"), bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: "unused", environment: ["HOME": folder.path, "PATH": "/usr/bin:/bin"])
        _ = controller.managedRequirementsProblem(for: .claude)
        let cli = bin.appendingPathComponent("claude"); try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        #expect(!controller.permissionModes(for: .claude).isEmpty)
        #expect(controller.executables.agents[.claude] == cli)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("state.json").path))
    }
}

@MainActor
extension ManagedSessionTests {
    @Test func stopDuringBackoffCancelsQueuedRecoveryAndRequiresOwnedBridgeProof() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        let pane = try #require(f.controller.record?.pane)
        let key = "claude:/actual-cwd#\(pane.pid).\(pane.startTime)"
        f.controller.considerSessions([.init(id: UUID(), sessionKey: key, agent: .claude, cwd: "/actual-cwd", clientName: nil, supportsChannel: false, tmuxPane: pane.id, connectedAt: f.clock.now, tmuxSocketPath: "/different.sock")])
        #expect(f.controller.sessionKey == nil)
        f.controller.considerSessions([.init(id: UUID(), sessionKey: key, agent: .claude, cwd: "/actual-cwd", clientName: nil, supportsChannel: false, tmuxPane: pane.id, connectedAt: f.clock.now, tmuxSocketPath: pane.socket)])
        #expect(f.controller.sessionKey == key)
        await f.host.die(); f.controller.refresh(); try await f.settle()
        f.controller.stopManagedSession(); try await f.settle()
        f.clock.advance(100); await Task.yield()
        #expect(f.controller.managedStatus == .stopped)
        #expect(f.controller.sessionKey == nil)
        #expect(await f.host.commands.count == 1)
    }
}
