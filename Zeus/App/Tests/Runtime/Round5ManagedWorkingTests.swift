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

}
