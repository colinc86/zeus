import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private actor ApplyCaptureHost: ManagedSessionHosting {
    let base: FakeManagedHost
    private var pause = true
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    init(_ base: FakeManagedHost) { self.base = base }
    func release() { continuation?.resume(); continuation = nil }
    func waitForCapture() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func capture(_ pane: ManagedPane, owner: String) async throws -> ManagedPaneSnapshot {
        let host: any ManagedSessionHosting = base
        let sample = try await host.capture(pane, owner: owner)
        if pause {
            pause = false
            await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
        }
        return sample
    }
    func sessions() async throws -> [ManagedTmuxSession] { await base.sessions() }
    func inspect(name: String, owner: String, pane: ManagedPane?) async throws -> ManagedPane? { try await base.inspect(name: name, owner: owner, pane: pane) }
    func create(name: String, owner: String, folder: String) async throws -> ManagedPane { try await base.create(name: name, owner: owner, folder: folder) }
    func launch(_ pane: ManagedPane, owner: String, command: ManagedLaunchCommand, folder: String) async throws -> ManagedPane { try await base.launch(pane, owner: owner, command: command, folder: folder) }
    func requestExit(_ pane: ManagedPane, owner: String) async throws { try await base.requestExit(pane, owner: owner) }
    func removePane(_ pane: ManagedPane, owner: String) async throws { try await base.removePane(pane, owner: owner) }
}

@MainActor struct ManagedSettingsApplicationTests {
    private func ready(_ f: ManagedFixture) async throws {
        f.controller.activate(); try await f.settle()
        try f.connectOwned()
        await f.host.setSnapshot(try N1Messages.frame(f.config.value?.agent ?? .claude, "before"))
        f.clock.advance(10, wake: false); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.idle))
    }

    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func idleApplyKeepsNativeIdentityAndUsesNewPromptAndMode(agent: AgentKind) async throws {
        let f = try ManagedFixture(agent: agent); defer { f.cleanup() }
        try await ready(f)
        let identity = try #require(f.controller.record?.conversation)
        var changed = try #require(f.config.value)
        changed.launchPrompt = "NEW instructions\nKeep this conversation."
        changed.permissionModeID = ManagedAgentLaunch.policies(for: agent)[1].mode.id
        var expected = changed
        if !f.controller.supportsInstructionChangesOnResume(for: agent) { expected.launchPrompt = identity.launchPrompt }
        f.config.value = changed; f.controller.configurationChanged()
        f.controller.applyManagedSettings(changed); try await f.settle()
        #expect(f.controller.record?.conversation?.nativeID == identity.nativeID)
        #expect(f.controller.record?.conversation?.nonce == identity.nonce)
        #expect(f.controller.record?.conversation?.launchPrompt == expected.launchPrompt)
        #expect(f.controller.managedAppliedConfiguration == expected)
        #expect(f.controller.managedSettingsApplication == nil)
        #expect(await f.host.commands.count == 2)
        #expect(await f.host.stops == 1)
        let command = try #require(await f.host.commands.last).arguments
        #expect(!command.contains(identity.firstMessage))
        #expect(command.contains(try #require(identity.nativeID)))
        switch agent {
        case .claude: #expect(command.contains(expected.launchPrompt) && command.contains("plan"))
        case .codex: #expect(command.contains("read-only") && command.contains { $0.hasPrefix("developer_instructions=") && $0.contains("Original instructions") })
        case .opencode:
            #expect(command.contains { $0.hasPrefix("OPENCODE_CONFIG_CONTENT=") && $0.contains("deny") })
            let text = try String(contentsOf: f.folder.appendingPathComponent("managed-launch/opencode-instructions.txt"), encoding: .utf8)
            #expect(text == changed.launchPrompt)
        case .other: Issue.record("Unexpected agent")
        }
        let restored = try ManagedSessionStore(url: f.folder.appendingPathComponent("state.json")).load()
        #expect(restored.appliedConfiguration == expected && restored.conversation?.nativeID == identity.nativeID)
    }

    @Test(arguments: ["working", "blocked", "draft", "unknown", "delivery"])
    func pendingChangeWaitsAndLaterEditsReplaceItUntilIdle(state: String) async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        switch state {
        case "working": await f.host.setSnapshot(try managedSnapshot("opencode-working"))
        case "blocked": await f.host.setSnapshot(try managedSnapshot("opencode-blocked-permission"))
        case "draft": await f.host.setSnapshot(try N1Messages.frame(.opencode, "three-lines"))
        case "unknown": await f.host.setSnapshot(.init(screen: "repainting", inputMetadata: "0|0|120|0|1"))
        default: f.controller.settingsApplicationAllowed = { false }
        }
        f.controller.refresh(); try await f.settle()
        var first = try #require(f.config.value); first.launchPrompt = "First edit"
        f.controller.applyManagedSettings(first); try await f.settle()
        var latest = first; latest.launchPrompt = "Last edit"; latest.permissionModeID = "deny"
        f.config.value = latest; f.controller.applyManagedSettings(latest); try await f.settle()
        #expect(f.controller.managedSettingsApplication?.configuration == latest)
        #expect(f.controller.managedSettingsApplication?.phase == .waiting)
        #expect(await f.host.commands.count == 1)
        #expect(await f.host.stops == 0)
        f.controller.settingsApplicationAllowed = { true }
        await f.host.setSnapshot(try N1Messages.frame(.opencode, "before"))
        f.controller.refresh(); try await f.settle()
        #expect(await f.host.commands.count == 2)
        #expect(await f.host.stops == 1)
        #expect(f.controller.managedAppliedConfiguration?.launchPrompt == "Last edit")
        #expect(f.controller.managedSettingsApplication == nil)
    }

    @Test func cancelOrStopNeverAppliesThePendingChange() async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        await f.host.setSnapshot(try N1Messages.frame(.opencode, "three-lines"))
        var changed = try #require(f.config.value); changed.launchPrompt = "Pending edit"
        f.controller.applyManagedSettings(changed); try await f.settle()
        f.controller.cancelManagedSettingsApplication()
        await f.host.setSnapshot(try N1Messages.frame(.opencode, "before"))
        f.controller.refresh(); try await f.settle()
        #expect(await f.host.commands.count == 1)
        #expect(await f.host.stops == 0)
        f.controller.settingsApplicationAllowed = { false }
        f.controller.applyManagedSettings(changed)
        f.controller.stopManagedSession(); try await f.settle()
        #expect(f.controller.managedSettingsApplication == nil)
        #expect(await f.host.commands.count == 1)
        #expect(await f.host.stops == 1)
    }

    @Test func confirmedSwitchIsSeparateFromResumeAndWaitsForHumanDraft() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        try await ready(f)
        let old = try #require(f.controller.record?.conversation)
        let folder = f.folder.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var changed = try #require(f.config.value); changed.agent = .codex; changed.folder = folder.path
        f.config.value = changed
        f.controller.applyManagedSettings(changed); try await f.settle()
        #expect(await f.host.stops == 0, "Resume can never switch native conversation identity")
        await f.host.setSnapshot(try N1Messages.frame(.claude, "three-lines"))
        f.controller.switchManagedSettings(changed); try await f.settle()
        #expect(await f.host.stops == 0)
        await f.host.setSnapshot(try N1Messages.frame(.claude, "before"))
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.record?.conversation?.agent == .codex)
        #expect(f.controller.record?.conversation?.nonce != old.nonce)
        #expect(f.controller.managedAppliedConfiguration?.folder == folder.path)
        #expect(await f.host.commands.count == 2)
        #expect(await f.host.stops == 1)
    }

    @Test(arguments: ["folder", "permission"])
    func invalidSettingsLeaveTheRunningPaneAlone(field: String) async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        try await ready(f)
        var changed = try #require(f.config.value)
        if field == "folder" { changed.folder = f.folder.appendingPathComponent("missing").path }
        else { changed.permissionModeID = "not-a-mode" }
        f.controller.switchManagedSettings(changed); try await f.settle()
        #expect(f.controller.managedSettingsApplicationError != nil)
        #expect(f.controller.managedStatus == .running(.idle))
        #expect(await f.host.stops == 0)
        #expect(await f.host.commands.count == 1)
    }

    @Test(arguments: ["replace", "cancel", "draft", "foreign"])
    func changesDuringCaptureAreRevalidatedBeforeTeardown(event: String) async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        let paused = ApplyCaptureHost(f.host)
        f.controller.hosting = paused
        var changed = try #require(f.config.value); changed.launchPrompt = "First edit"
        f.controller.applyManagedSettings(changed)
        await paused.waitForCapture()
        switch event {
        case "replace": changed.launchPrompt = "Latest edit"; f.controller.applyManagedSettings(changed)
        case "cancel": f.controller.cancelManagedSettingsApplication()
        case "draft": await f.host.setSnapshot(try N1Messages.frame(.opencode, "three-lines"))
        default: await f.host.changeOwner("zeus")
        }
        await paused.release(); try await f.settle()
        if event == "foreign" { #expect(f.controller.managedSettingsApplicationError != nil) }
        else { #expect(f.controller.managedSettingsApplicationError == nil) }
        let stops = await f.host.stops, count = await f.host.commands.count
        #expect(stops == (event == "replace" ? 1 : 0), "pending: \(String(describing: f.controller.managedSettingsApplication)), status: \(f.controller.managedStatus)")
        #expect(count == (event == "replace" ? 2 : 1))
        if event == "replace" { #expect(f.controller.managedAppliedConfiguration?.launchPrompt == "Latest edit") }
        if event == "draft" { #expect(f.controller.managedSettingsApplication?.phase == .waiting) }
    }
}
