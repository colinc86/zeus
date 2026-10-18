import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private actor RestartCaptureHost: ManagedSessionHosting {
    let base: FakeManagedHost
    let changed: ManagedPaneSnapshot
    private var captures = 0
    init(base: FakeManagedHost, changed: ManagedPaneSnapshot) { self.base = base; self.changed = changed }
    func sessions() async throws -> [ManagedTmuxSession] { await base.sessions() }
    func inspect(name: String, owner: String, pane: ManagedPane?) async throws -> ManagedPane? { try await base.inspect(name: name, owner: owner, pane: pane) }
    func create(name: String, owner: String, folder: String) async throws -> ManagedPane { try await base.create(name: name, owner: owner, folder: folder) }
    func launch(_ pane: ManagedPane, owner: String, command: ManagedLaunchCommand, folder: String) async throws -> ManagedPane { try await base.launch(pane, owner: owner, command: command, folder: folder) }
    func requestExit(_ pane: ManagedPane, owner: String) async throws { try await base.requestExit(pane, owner: owner) }
    func removePane(_ pane: ManagedPane, owner: String) async throws { try await base.removePane(pane, owner: owner) }
    func capture(_ pane: ManagedPane, owner: String) async throws -> ManagedPaneSnapshot {
        captures += 1
        if captures == 2 { await base.setSnapshot(changed) }
        return try await base.capture(pane, owner: owner)
    }
}

@MainActor struct SafeManagedRestartTests {
    private func ready(_ f: ManagedFixture) async throws {
        f.controller.activate(); try await f.settle(); try f.connectOwned()
        f.clock.advance(10, wake: false)
        await f.host.setSnapshot(try N1Messages.frame(.opencode, "before"))
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.canAcceptInput)
    }

    @Test(arguments: ["working", "draft", "blocked", "delivery"])
    func ordinaryRestartWaitsThenResumesTheSameConversation(state: String) async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        let identity = try #require(f.controller.record?.conversation)
        switch state {
        case "working": await f.host.setSnapshot(try managedSnapshot("opencode-working"))
        case "draft": await f.host.setSnapshot(try N1Messages.frame(.opencode, "three-lines"))
        case "blocked": await f.host.setSnapshot(try managedSnapshot("opencode-blocked-permission"))
        default: f.controller.settingsApplicationAllowed = { false }
        }
        f.controller.refresh(); try await f.settle()
        f.controller.refresh(); try await f.settle()
        f.controller.restartManagedSession(); try await f.settle()
        #expect(f.controller.managedSettingsApplication?.kind == .restart)
        #expect(f.controller.managedSettingsApplication?.phase == .waiting)
        #expect(await f.host.stops == 0)
        #expect(await f.host.commands.count == 1)
        f.controller.settingsApplicationAllowed = { true }
        await f.host.setSnapshot(try N1Messages.frame(.opencode, "before"))
        f.controller.refresh(); try await f.settle()
        #expect(await f.host.stops == 1)
        #expect(await f.host.commands.count == 2)
        #expect(f.controller.record?.conversation?.nativeID == identity.nativeID)
        #expect(f.controller.record?.conversation?.nonce == identity.nonce)
        #expect(f.controller.managedSettingsApplication == nil)
    }

    @Test func cancelAndChangedFinalCaptureNeverStopTheAgent() async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        f.controller.settingsApplicationAllowed = { false }
        f.controller.restartManagedSession()
        f.controller.cancelManagedSettingsApplication()
        f.controller.settingsApplicationAllowed = { true }
        f.controller.reconsiderSettingsApplication(); try await f.settle()
        #expect(await f.host.stops == 0)
        f.controller.hosting = RestartCaptureHost(base: f.host, changed: try managedSnapshot("opencode-working"))
        f.controller.restartManagedSession(); try await f.settle()
        #expect(await f.host.stops == 0)
        #expect(f.controller.managedSettingsApplication?.phase == .waiting)
    }

    @Test func immediateRecoveryRequiresLongBlockAndRejectsChangedPrompt() async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        #expect(f.controller.managedRestartNowToken == nil)
        await f.host.setSnapshot(try managedSnapshot("opencode-blocked-permission"))
        f.controller.refresh(); try await f.settle(); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedRestartNowToken == nil)
        f.clock.advance(121, wake: false)
        let token = try #require(f.controller.managedRestartNowToken)
        await f.host.setSnapshot(try N1Messages.frame(.opencode, "before"))
        f.controller.restartManagedSessionNow(token: token); try await f.settle()
        #expect(await f.host.stops == 0)
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedRestartNowToken == nil)
        f.controller.restartManagedSessionNow(token: token); try await f.settle()
        #expect(await f.host.stops == 0)
    }

    @Test func changedBlockedFingerprintStartsANewRecoveryWindow() async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        let original = try managedSnapshot("opencode-blocked-permission")
        await f.host.setSnapshot(original)
        f.controller.refresh(); try await f.settle(); f.controller.refresh(); try await f.settle()
        f.clock.advance(121, wake: false)
        let old = try #require(f.controller.managedRestartNowToken)
        let changed = ManagedPaneSnapshot(screen: original.screen.replacingOccurrences(of: "M0_PERMISSION", with: "M0_OTHER_PERMISSION"), inputMetadata: original.inputMetadata)
        // Alter the dialog itself, retaining the classifier's permission markers.
        await f.host.setSnapshot(changed)
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedRestartNowToken == nil)
        f.controller.restartManagedSessionNow(token: old); try await f.settle()
        #expect(await f.host.stops == 0)
    }

    @Test func crashRecoverySatisfiesAWaitingRestartWithoutRestartingTwice() async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        await f.host.setSnapshot(try managedSnapshot("opencode-working"))
        f.controller.refresh(); try await f.settle()
        f.controller.restartManagedSession(); try await f.settle()
        #expect(f.controller.managedSettingsApplication?.kind == .restart)
        await f.host.die(); f.controller.refresh(); try await f.settle()
        f.clock.advance(2)
        try await eventually { f.controller.managedStatus == .starting }
        try await f.settle()
        #expect(f.controller.managedSettingsApplication == nil)
        try await f.prepareIdleRestart()
        #expect(await f.host.commands.count == 2)
    }

    @Test func confirmedDeadProcessRecoveryKeepsNativeIdentity() async throws {
        let f = try ManagedFixture(agent: .opencode); defer { f.cleanup() }
        try await ready(f)
        let nativeID = f.controller.record?.conversation?.nativeID
        await f.host.die()
        f.controller.refresh(); try await f.settle()
        let token = try #require(f.controller.managedRestartNowToken)
        f.controller.restartManagedSessionNow(token: token); try await f.settle()
        #expect(await f.host.commands.count == 2)
        #expect(f.controller.record?.conversation?.nativeID == nativeID)
    }
}
