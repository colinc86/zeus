import Foundation
import Testing
import ZeusDesign
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5QueueTests {
    @Test func managedQueueCaptionsFollowWorkingBlockedAndStopped() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start()
        #expect(await f.runtime.sendUserMessage("Wait", deliveryID: "d_state") == .queued(reason: "Waiting for Claude Code to start."))
        f.managed.clock.advance(10, wake: false)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-working"))
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.userMessageDeliveries.first?.reason == "Waiting for Claude Code to finish what it's doing.")
        await f.managed.host.setSnapshot(try managedSnapshot("claude-trust"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        #expect(f.runtime.userMessageDeliveries.first?.reason == "Waiting until you answer Claude Code in Terminal.")
        f.managed.controller.stopManagedSession(); try await f.managed.settle()
        f.managed.clock.advance(121, wake: false); f.runtime.processDueDeliveries()
        #expect(f.runtime.userMessageDeliveries.first?.reason == "Claude Code is stopped. Start it to send this.")
        #expect(f.runtime.deliveryIssue?.detail == "Claude Code is stopped. Start it to send this.")
        #expect(f.status.problem == f.runtime.deliveryIssue?.detail)
        #expect(!f.runtime.canRetryPendingDeliveries)
    }

}
