import Foundation
import Testing
import ZeusDesign
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5ManagedWorkingTests {
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
