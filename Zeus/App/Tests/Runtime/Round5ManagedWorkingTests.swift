import Foundation
import Testing
import ZeusDesign
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5ManagedWorkingTests {
    private func claudeIdle(completed: String) throws -> ManagedPaneSnapshot {
        let idle = try managedSnapshot("claude-idle")
        var lines = idle.screen.components(separatedBy: "\n")
        let composer = try #require(lines.firstIndex { $0.hasPrefix("────────") })
        let history = completed.components(separatedBy: "\n")
        #expect(history.count < composer)
        // Replace history, keeping the real composer's rows/cursor metadata aligned.
        for index in 0..<composer { lines[index] = index < history.count ? history[index] : "" }
        return .init(screen: lines.joined(separator: "\n"), inputMetadata: idle.inputMetadata)
    }

    @Test func newClaudeCompletionEndsAFastTurnButAnOldFooterOrUserEchoCannot() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let previous = "❯ previous delivery\n⏺ Previous answer\n✻ Cogitated for 0s · done 2:10 PM"
        await f.managed.host.setSnapshot(try claudeIdle(completed: previous))
        f.managed.controller.refresh(); try await f.managed.settle()
        let key = try #require(f.managed.controller.sessionKey)
        #expect(await f.runtime.sendUserMessage("Quick Read, no Zeus reply", deliveryID: "d_fast") == .delivered)
        let since = try #require(f.runtime.assistantActivity).since
        // An idle repaint with only the newly submitted user input is not completion.
        await f.managed.host.setSnapshot(try claudeIdle(completed: previous + "\n❯ new delivery"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.since == since)
        #expect(!f.runtime.activityWorkingSeen.contains(key))
        // Identical native footer words/time still refer to a different, now completed user turn.
        await f.managed.host.setSnapshot(try claudeIdle(completed: previous + "\n❯ new delivery\n⏺ New answer\n✻ Cogitated for 0s · done 2:10 PM"))
        f.managed.clock.advance(1, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity == nil)
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity == nil, "Completion evidence must not revive an ended response")
    }

    /// zeus_say ends the typing row, but the answer (and its reply classification) lasts until the native turn completes.
    @Test func aNewNativeCompletionEndsTheAnswerAfterZeusSayEndedTheRow() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let previous = "❯ previous delivery\n⏺ Previous answer\n✻ Cogitated for 0s · done 2:10 PM"
        await f.managed.host.setSnapshot(try claudeIdle(completed: previous))
        f.managed.controller.refresh(); try await f.managed.settle()
        let key = try #require(f.managed.controller.sessionKey)
        #expect(await f.runtime.sendUserMessage("Two messages, please", deliveryID: "d_answer") == .delivered)
        func say(_ text: String) async throws -> CardOrigin? {
            #expect(!(await f.runtime.callTool("zeus_say", arguments: ["text": .string(text)], sessionKey: key)).isError)
            return try #require(f.cards.values.last).origin
        }
        #expect(try await say("First") == .reply)
        #expect(f.runtime.assistantActivity == nil)
        #expect(try await say("Second") == .reply)
        // An idle repaint with only the submitted input is not the end of the turn.
        await f.managed.host.setSnapshot(try claudeIdle(completed: previous + "\n❯ new delivery"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(try await say("Third") == .reply)
        await f.managed.host.setSnapshot(try claudeIdle(completed: previous + "\n❯ new delivery\n⏺ New answer\n✻ Cogitated for 0s · done 2:10 PM"))
        f.managed.clock.advance(1, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(try await say("Later, on its own") == .unprompted)
    }
    @Test func completionParsingRejectsIndentedContentAndMissingNativeFooter() throws {
        #expect(ZeusRuntime.claudeCompletedTurn(try claudeIdle(completed: "❯ user\n  ✻ Cogitated for 0s · done 2:10 PM")) == nil)
        #expect(ZeusRuntime.claudeCompletedTurn(try claudeIdle(completed: "❯ user\n⏺ Still thinking")) == nil)
    }

    @Test func realScheduledCompletionCannotEndANewerImplicitUserResponse() async throws {
        struct Capture: Decodable { let screen: String; let inputMetadata: String }
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: root.appendingPathComponent("TestFixtures/live/sa1/claude-scheduled-idle.json")))
        let scheduled = ManagedPaneSnapshot(screen: capture.screen, inputMetadata: capture.inputMetadata)
        var lines = scheduled.screen.components(separatedBy: "\n")
        let plain = scheduled.plainLines
        let begin = try #require(plain.firstIndex { $0.hasPrefix("✻ Running scheduled task") })
        let composer = try #require(plain[begin...].firstIndex { $0.hasPrefix("────────") })
        for index in begin..<composer { lines[index] = "" }
        let before = ManagedPaneSnapshot(screen: lines.joined(separator: "\n"), inputMetadata: capture.inputMetadata)
        #expect(ManagedPaneClassifier.classify(before, agent: .claude) == .idle)
        #expect(ManagedPaneClassifier.classify(scheduled, agent: .claude) == .idle)
        #expect(ZeusRuntime.claudeCompletedTurn(before) != nil)
        #expect(ZeusRuntime.claudeCompletedTurn(scheduled) == nil)
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(before); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(await f.runtime.sendUserMessage("New user input", deliveryID: "d_after_schedule_setup") == .delivered)
        await f.managed.host.setSnapshot(scheduled)
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity != nil, "The scheduler's completion is not this delivery's completion")
        let laterUser = ManagedPaneSnapshot(screen: scheduled.screen + "\n❯ later user\n⏺ Reply\n✻ Worked for 0s · done 2:14 PM", inputMetadata: capture.inputMetadata)
        #expect(ZeusRuntime.claudeCompletedTurn(laterUser) != nil, "A later user turn must not inherit the scheduler exclusion")
    }

    @Test func managedWorkingSamplesPreserveExplicitTTLAndIdleDoesNotEndItEarly() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        f.runtime.noteWorkingActivity(sessionKey: key, detail: "Thirty seconds", progress: nil, ttl: 30)
        let deadline = try #require(f.runtime.activityRecords[key]).deadline
        await f.managed.host.setSnapshot(try managedSnapshot("claude-working"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.activityRecords[key]?.deadline == deadline)
        await f.managed.host.setSnapshot(try claudeIdle(completed: "❯ new delivery\n⏺ Finished\n✻ Cogitated for 0s · done 2:10 PM"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.phase == .working, "Explicit status remains earned until its TTL or auto")
        try await eventually { f.managed.clock.pendingDeadlines.contains(deadline) }
        f.managed.clock.advance(24); try await f.managed.settle()
        try await eventually { f.runtime.assistantActivity == nil }
    }
    @Test func repeatedWorkingSamplesKeepOnlyAnExistingActivityAlive() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        #expect(await f.runtime.sendUserMessage("Long work", deliveryID: "d_long") == .delivered)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-working"))
        for _ in 0..<4 {
            f.managed.clock.advance(200, wake: false)
            f.managed.controller.refresh(); try await f.managed.settle()
            #expect(f.runtime.assistantActivity?.sessionKey == key)
        }
        f.runtime.endAssistantActivity(sessionKey: key)
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity == nil, "A reply-ended activity must not be resurrected by screen evidence")
    }

    /// An agent that finishes its turn without `zeus_say` must not leave Zeus "thinking" for five minutes.
    @Test func anIdleScreenAfterWorkEndsTheActivityWithoutAReply() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        #expect(await f.runtime.sendUserMessage("Thanks, all done", deliveryID: "d_done") == .delivered)
        #expect(f.runtime.assistantActivity?.sessionKey == key)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-working"))
        f.managed.clock.advance(2, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.sessionKey == key)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-idle"))
        f.managed.clock.advance(3, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity == nil, "A positive idle screen after work ends the row")
    }

    /// Idle right after delivery is not "finished": the agent may not have started yet.
    @Test func idleBeforeTheAgentStartsKeepsTheActivityUntilTheGraceElapses() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        #expect(await f.runtime.sendUserMessage("Quick one", deliveryID: "d_quick") == .delivered)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-idle"))
        f.managed.clock.advance(5, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity?.sessionKey == key, "Five seconds of idle is not evidence the turn ended")
        f.managed.clock.advance(ZeusRuntime.managedIdleEndsActivityAfter, wake: false)
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.assistantActivity == nil, "After the grace period an idle screen ends it")
    }
}
