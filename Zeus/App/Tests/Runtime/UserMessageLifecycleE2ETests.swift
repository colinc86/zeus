import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

extension ZeusE2ETests {
    @Test @MainActor func realBridgeUpdatesStableMessageLifecycleAcrossPollingPushAckDiscardAndRelaunch() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let queuedID = UserMessageDelivery.makeID()
        if case .queued = await f.runtime.sendUserMessage("Saved before connect", deliveryID: queuedID) {} else { Issue.record("Expected queue") }
        let bridge = try await f.bridge()
        #expect(try await bridge.call("zeus_get_responses")["items"]?[0]?["delivery_id"] == .string(queuedID))
        try await eventually { f.runtime.userMessageDeliveries.first { $0.id == queuedID }?.state == .acked }
        f.routing.deliveryMethod = .channel
        let pushedID = UserMessageDelivery.makeID()
        #expect(await f.runtime.sendUserMessage("One channel message", deliveryID: pushedID) == .delivered)
        #expect(try await bridge.userMessage()["meta"]?["delivery_id"] == .string(pushedID))
        #expect(f.runtime.userMessageDeliveries.first { $0.id == pushedID }?.state == .delivered)
        _ = try await bridge.call("zeus_say", ["text": "Done"])
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [.string(pushedID)]])
        #expect(f.runtime.userMessageDeliveries.first { $0.id == pushedID }?.state == .acked && f.runtime.assistantActivity == nil)
        f.routing.deliveryMethod = .polling
        let discardedID = UserMessageDelivery.makeID()
        _ = await f.runtime.sendUserMessage("Do not send", deliveryID: discardedID)
        f.runtime.discardPendingDeliveries()
        try f.restart()
        try await eventually { f.runtime.sessions.count == 1 }
        #expect(f.runtime.userMessageDeliveries.allSatisfy { $0.recovered })
        #expect(f.runtime.userMessageDeliveries.first { $0.id == discardedID }?.state == .discarded)
        #expect(f.runtime.userMessageDeliveries.first { $0.id == pushedID }?.state == .acked)
        #expect(try await bridge.call("zeus_get_responses")["items"] == [])
        if case .failed = await f.runtime.sendUserMessage("Do not send", deliveryID: discardedID) {} else { Issue.record("Discarded ID must not resurrect") }
        try await bridge.finish()
    }
}
