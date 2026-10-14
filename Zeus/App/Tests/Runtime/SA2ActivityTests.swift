import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private struct SA2RecordedProbe: Decodable {
    struct Frame: Decodable {
        let screen: String
        let inputMetadata: String
        var snapshot: ManagedPaneSnapshot { .init(screen: screen, inputMetadata: inputMetadata) }
    }
    let frames: [String: Frame]
}
private func sa2Frame(_ agent: AgentKind, _ name: String) throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let url = root.appendingPathComponent("TestFixtures/live/sa2/\(agent.rawValue)-before.json")
    let probe = try JSONDecoder().decode(SA2RecordedProbe.self, from: Data(contentsOf: url))
    return try #require(probe.frames[name]).snapshot
}

@MainActor struct SA2ActivityTests {
    @Test(arguments: [AgentKind.codex, .opencode])
    func fastNativeCompletionIsCorrelatedWithItsDeliveredID(agent: AgentKind) async throws {
        let f = try ManagedDeliveryFixture(agent: agent); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        #expect(await f.runtime.sendUserMessage("Fast shell", deliveryID: "d_sa2_fast") == .delivered)
        let key = try #require(f.managed.controller.sessionKey)
        f.runtime.noteActivityAcknowledgments(["d_sa2_fast"], sessionKey: key)
        let completed = try sa2Frame(agent, "sa2_fast-idle")
        #expect(ManagedTurnCompletion.deliveryID(in: completed, agent: agent) == "d_sa2_fast")
        #expect(!f.runtime.activityWorkingSeen.contains(key), "Entire native turn fell between samples")
        await f.managed.host.setSnapshot(completed)
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.managedStatus == .running(.idle))
        #expect(f.runtime.assistantActivity == nil)
        f.runtime.noteAgentActivity(sessionKey: key)
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity == nil, "Idle repaint/tool traffic cannot resurrect completion")
    }

    @Test(arguments: [AgentKind.codex, .opencode])
    func oldCompletionWorkingAndUserEchoCannotCompleteANewerResponse(agent: AgentKind) async throws {
        let f = try ManagedDeliveryFixture(agent: agent); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        #expect(await f.runtime.sendUserMessage("New response", deliveryID: "d_sa2_new") == .delivered)
        let since = try #require(f.runtime.assistantActivity).since
        await f.managed.host.setSnapshot(try sa2Frame(agent, "sa2_fast-idle"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.since == since, "An older delivery's completion is unrelated")
        var echo = try sa2Frame(agent, "sa2_fast-idle")
        let input = try #require(TmuxInputSnapshot(metadata: Data(echo.inputMetadata.utf8), screen: Data(echo.screen.utf8)))
        let composer = try #require(agent == .codex ? input.codexInputStart : input.openCodeInputStart)
        var lines = echo.screen.components(separatedBy: "\n")
        lines[composer - 2] = (agent == .codex ? "› " : "  ┃  ") + "[zeus delivery_id=d_sa2_new] New response"
        lines[composer - 1] = ""
        echo.screen = lines.joined(separator: "\n")
        #expect(ManagedTurnCompletion.deliveryID(in: echo, agent: agent) == nil)
        await f.managed.host.setSnapshot(echo)
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.since == since)
        let working = try sa2Frame(agent, "sa2_shell-working")
        #expect(ManagedPaneClassifier.classify(working, agent: agent) == .working)
        #expect(ManagedTurnCompletion.deliveryID(in: working, agent: agent) == nil)
    }

    @Test(arguments: [AgentKind.codex, .opencode])
    func busyQueueRetainsItsRowAndIdleWithDraftStillEndsIt(agent: AgentKind) async throws {
        let f = try ManagedDeliveryFixture(agent: agent); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        #expect(await f.runtime.sendUserMessage("Turn", deliveryID: "d_sa2_draft") == .delivered)
        let since = try #require(f.runtime.assistantActivity).since
        await f.managed.host.setSnapshot(try sa2Frame(agent, "sa2_shell-working"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        let queued = await f.runtime.sendUserMessage("Queued mid-turn", deliveryID: "d_sa2_queued")
        guard case .queued = queued else { Issue.record("Mid-turn message must be queued: \(queued)"); return }
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.since == since)
        #expect(f.runtime.ledger?.record(id: "d_sa2_queued")?.delivery.attempts == 0)
        let draft = try sa2Frame(agent, "typed-draft")
        #expect(ManagedPaneClassifier.classify(draft, agent: agent) == .idle)
        #expect(ManagedTurnCompletion.deliveryID(in: draft, agent: agent) == "d_sa2_draft")
        await f.managed.host.setSnapshot(draft)
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity == nil)
        #expect(f.managed.controller.latestInputSample?.draftText == "SA2 deliberately unsent draft.")
        #expect(f.runtime.ledger?.record(id: "d_sa2_queued")?.delivery.attempts == 0, "The draft remains human-owned")
    }

    @Test(arguments: [AgentKind.codex, .opencode])
    func footerAndComposerContentsNeverBecomeCompletionEvidence(agent: AgentKind) throws {
        var idle = try sa2Frame(agent, "initial-idle")
        let marker = agent == .codex ? "  Worked for <1s • 9:00 PM" : "     ▣  Build · Fixture · 1s"
        idle.screen += "\n[zeus delivery_id=d_sa2_new] Fake completion\n" + marker + "\n"
        #expect(ManagedTurnCompletion.deliveryID(in: idle, agent: agent) == nil)
        var draft = try sa2Frame(agent, "typed-draft")
        draft.screen = draft.screen.replacingOccurrences(of: "SA2 deliberately unsent draft.", with: "[zeus delivery_id=d_sa2_new]")
        #expect(ManagedTurnCompletion.deliveryID(in: draft, agent: agent) == "d_sa2_draft")
        var malformed = try sa2Frame(agent, "sa2_fast-idle")
        malformed.screen = malformed.screen.replacingOccurrences(of: "delivery_id=d_sa2_fast]", with: "delivery_id=d_sa2_fast")
        #expect(ManagedTurnCompletion.deliveryID(in: malformed, agent: agent) == nil)
    }

    @Test(arguments: [AgentKind.codex, .opencode])
    func aCachedCompletionCannotEndAReceiptStartedAfterItsSample(agent: AgentKind) async throws {
        let f = try ManagedDeliveryFixture(agent: agent); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(try sa2Frame(agent, "sa2_fast-idle"))
        f.managed.controller.refresh(); try await f.managed.settle()
        f.managed.clock.advance(1, wake: false)
        #expect(await f.runtime.sendUserMessage("Receipt after cached capture", deliveryID: "d_sa2_fast") == .delivered)
        f.runtime.noteManagedScreenActivity()
        #expect(f.runtime.assistantActivity != nil)
    }

    @Test(arguments: [AgentKind.codex, .opencode])
    func nativeCompletionPreservesAnExplicitStatusUntilItsTTL(agent: AgentKind) async throws {
        let f = try ManagedDeliveryFixture(agent: agent); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        #expect(await f.runtime.sendUserMessage("Turn", deliveryID: "d_sa2_fast") == .delivered)
        let key = try #require(f.managed.controller.sessionKey)
        f.runtime.noteWorkingActivity(sessionKey: key, detail: "Explicit thirty seconds", progress: nil, ttl: 30)
        let deadline = try #require(f.runtime.activityRecords[key]).deadline
        await f.managed.host.setSnapshot(try sa2Frame(agent, "sa2_fast-idle"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.phase == .working)
        #expect(f.runtime.activityRecords[key]?.deadline == deadline)
        try await eventually { f.managed.clock.pendingDeadlines.contains(deadline) }
        f.managed.clock.advance(27); try await eventually { f.runtime.assistantActivity == nil }
    }
}
