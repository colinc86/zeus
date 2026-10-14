import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class OwnFakeScreen: OwnSessionScreenReading {
    var frame = ManagedPaneSnapshot(screen: "unknown", inputMetadata: "")
    var captures: [OwnSessionScreenDestination] = []
    var hold = false
    var waits: [CheckedContinuation<Void, Never>] = []
    var wait: CheckedContinuation<Void, Never>? { waits.first }
    func capture(_ destination: OwnSessionScreenDestination, stillAllowed: @MainActor () -> Bool) async throws -> ManagedPaneSnapshot {
        captures.append(destination)
        let result = frame
        if hold { await withCheckedContinuation { waits.append($0) } }
        return result
    }
    func release() { let pending = waits; waits.removeAll(); for item in pending { item.resume() } }
}
private func ownRecorded(_ agent: AgentKind, _ name: String, group: String = "sa3") throws -> ManagedPaneSnapshot {
    struct Frame: Decodable { let screen: String; let inputMetadata: String }
    struct Probe: Decodable { let frames: [String: Frame] }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let value = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: root.appendingPathComponent("TestFixtures/live/\(group)/\(agent.rawValue)-probe.json")))
    let frame = try #require(value.frames[name])
    return .init(screen: frame.screen, inputMetadata: frame.inputMetadata)
}
@MainActor struct OwnScreenActivityTests {
    private func connect(_ f: RuntimeFixture, _ agent: AgentKind = .claude) -> String {
        let key = "\(agent.rawValue):/assistant#17.100"
        f.runtime.registerSession(.init(id: UUID(), sessionKey: key, agent: agent, cwd: "/assistant", clientName: "Own",
            supportsChannel: false, tmuxPane: "%0", connectedAt: f.clock.now, tmuxSocketPath: "/test/tmux.sock"))
        f.routing.assistantSessionKey = key; f.routing.deliveryMethod = .tmux; f.routing.tmuxTarget = "%0"
        return key
    }
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func nativeCompletionBetweenSamplesEndsOnlyItsOwnInput(_ agent: AgentKind) async throws {
        let screen = OwnFakeScreen(), f = try RuntimeFixture(ownScreenReader: screen); defer { screen.release(); f.stop() }
        let key = connect(f, agent)
        screen.frame = try ownRecorded(agent, "initial-idle")
        #expect(await f.runtime.sendUserMessage("Fast native turn", deliveryID: "d_sa3_second") == .delivered)
        try await eventually { screen.captures.count == 1 }
        #expect(f.runtime.assistantActivity != nil)
        screen.frame = try ownRecorded(agent, "second-complete")
        f.clock.advance(3)
        try await eventually { f.runtime.assistantActivity == nil }
        #expect(f.runtime.ownScreenTask == nil && f.runtime.ownScreenSamplingLease == nil)
        let count = screen.captures.count
        f.clock.advance(60); _ = await f.call("zeus_ack", ["delivery_ids": ["d_sa3_second"]], session: key)
        #expect(screen.captures.count == count && f.runtime.assistantActivity == nil && f.cards.values.isEmpty)
    }
    @Test func workingThenIdleEndsAndNeverCreatesManagedPresentation() async throws {
        let screen = OwnFakeScreen(), f = try RuntimeFixture(ownScreenReader: screen); defer { f.stop() }
        _ = connect(f)
        screen.frame = .init(screen: "────────────────\n❯ \n────────────────\n", inputMetadata: "2|1|120|0|1|")
        #expect(await f.runtime.sendUserMessage("Work") == .delivered)
        try await eventually { screen.captures.count == 1 }
        screen.frame = .init(screen: "✻ Thinking…\n────────────────\n❯ \n────────────────\n", inputMetadata: "2|2|120|0|1|")
        f.clock.advance(3)
        try await eventually { f.runtime.activityWorkingSeen.count == 1 }
        screen.frame = .init(screen: "────────────────\n❯ \n────────────────\n", inputMetadata: "2|1|120|0|1|")
        f.clock.advance(3)
        try await eventually { f.runtime.assistantActivity == nil }
        #expect(f.runtime.managedStatus == .off && f.cards.values.isEmpty && f.runtime.managedDraftAlertCardID == nil)
    }
    @Test(arguments: [AgentKind.codex, .opencode])
    func recordedWorkingThenIdleWithHumanDraftEndsWithoutDraftCards(_ agent: AgentKind) async throws {
        let screen = OwnFakeScreen(), f = try RuntimeFixture(ownScreenReader: screen); defer { f.stop() }
        _ = connect(f, agent)
        screen.frame = try ownRecorded(agent, "sa2_shell-working", group: "sa2")
        #expect(await f.runtime.sendUserMessage("Native work", deliveryID: "d_sa2_draft") == .delivered)
        try await eventually { f.runtime.activityWorkingSeen.count == 1 }
        screen.frame = try ownRecorded(agent, "typed-draft", group: "sa2")
        f.clock.advance(3)
        try await eventually { f.runtime.assistantActivity == nil }
        #expect(f.cards.values.isEmpty && !f.runtime.managedDraftWaiting && f.runtime.managedDraftAlertCardID == nil)
    }
    @Test func aRecordedPermissionPromptNeitherEndsActivityNorMirrorsACard() async throws {
        let screen = OwnFakeScreen(), f = try RuntimeFixture(ownScreenReader: screen); defer { f.stop() }
        _ = connect(f); screen.frame = try managedSnapshot("claude-blocked-permission")
        #expect(await f.runtime.sendUserMessage("Busy") == .delivered)
        try await eventually { screen.captures.count == 1 }
        f.clock.advance(21)
        try await eventually { screen.captures.count == 2 }
        #expect(f.runtime.assistantActivity != nil && f.cards.values.isEmpty && f.runtime.managedBlockedCardID == nil)
    }
    @Test func noImplicitActivityNoSelectionNoMatchingNamespaceMeansNoCapture() async throws {
        let screen = OwnFakeScreen(), f = try RuntimeFixture(ownScreenReader: screen); defer { f.stop() }
        let key = connect(f)
        f.clock.advance(60); #expect(screen.captures.isEmpty)
        f.routing.tmuxTarget = nil
        #expect(await f.runtime.sendUserMessage("No selected pane") == .delivered)
        #expect(f.runtime.ownScreenLease() == nil && screen.captures.isEmpty)
        f.routing.tmuxTarget = "%0"; f.routing.tmuxTargetSocketPath = "/wrong/socket"
        #expect(f.runtime.ownScreenLease() == nil)
        f.routing.tmuxTargetSocketPath = "/test/tmux.sock"
        _ = await f.call("zeus_set_status", ["state": "working", "ttl_seconds": 30], session: key)
        #expect(f.runtime.ownScreenLease() == nil && screen.captures.isEmpty)
        let deadline = f.runtime.activityRecords[key]?.deadline
        f.clock.advance(29); #expect(f.runtime.activityRecords[key]?.deadline == deadline)
        f.clock.advance(1); try await eventually { f.runtime.assistantActivity == nil }
    }
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func oldFooterCannotEndNewInputAndExplicitTTLDoesNotSample(_ agent: AgentKind) async throws {
        let screen = OwnFakeScreen(), f = try RuntimeFixture(ownScreenReader: screen); defer { f.stop() }
        let key = connect(f, agent); screen.frame = try ownRecorded(agent, "second-complete")
        #expect(await f.runtime.sendUserMessage("New", deliveryID: "d_sa4_new") == .delivered)
        try await eventually { screen.captures.count == 1 }
        #expect(f.runtime.assistantActivity != nil)
        _ = await f.call("zeus_set_status", ["state": "working", "ttl_seconds": 30], session: key)
        let count = screen.captures.count, deadline = f.runtime.activityRecords[key]?.deadline
        f.clock.advance(29); #expect(screen.captures.count == count && f.runtime.activityRecords[key]?.deadline == deadline)
        f.clock.advance(1); try await eventually { f.runtime.assistantActivity == nil }
    }
    @Test(arguments: ["new-response", "pane", "socket", "session", "disconnect", "stop", "say"])
    func suspendedCaptureCannotEndReplacementOrOutliveAuthorization(_ change: String) async throws {
        let screen = OwnFakeScreen(), f = try RuntimeFixture(ownScreenReader: screen); defer { screen.release(); f.stop() }
        let key = connect(f); screen.frame = try ownRecorded(.claude, "second-complete"); screen.hold = true
        #expect(await f.runtime.sendUserMessage("First", deliveryID: "d_sa3_second") == .delivered)
        try await eventually { screen.wait != nil }
        switch change {
        case "new-response": #expect(await f.runtime.sendUserMessage("New", deliveryID: "d_sa4_new") == .delivered)
        case "pane": f.routing.tmuxTarget = "%1"
        case "socket": f.routing.tmuxTargetSocketPath = "/other/server"
        case "session": f.routing.assistantSessionKey = "claude:/other#19.100"
        case "disconnect": f.runtime.unregisterSession(id: try #require(f.runtime.sessions.first?.id), sessionKey: key)
        case "stop": f.runtime.stop()
        default: _ = await f.call("zeus_say", ["text": "Done"], session: key)
        }
        // Do not launch a second held fake capture while releasing the first.
        screen.hold = false; screen.frame = .init(screen: "unknown", inputMetadata: "")
        screen.release(); await Task.yield(); await Task.yield()
        if ["disconnect", "stop", "say"].contains(change) { #expect(f.runtime.assistantActivity == nil) }
        else { #expect(f.runtime.assistantActivity != nil) }
    }
}
