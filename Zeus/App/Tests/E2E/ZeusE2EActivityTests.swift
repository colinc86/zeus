import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

extension ZeusE2ETests {
    @Test func realBridgeSayThenAckNeverRestartsCompletedActivity() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try await f.bridge()
        #expect(await f.runtime.sendUserMessage("Please reply, then ack") == .delivered)
        let push = try await bridge.userMessage()
        let deliveryID = try #require(push["meta"]?["delivery_id"])
        #expect(f.runtime.assistantActivity?.phase == .sent)
        let reply = try await bridge.call("zeus_say", ["text": "Finished."])
        let replyID = try e2eString(reply["card_id"])
        #expect(f.cards.card(id: replyID)?.body == "Finished.")
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        let ack = try await bridge.call("zeus_ack", ["delivery_ids": [deliveryID]])
        #expect(ack["acked"] == .array([deliveryID]))
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [deliveryID]])
        let poll = try await bridge.call("zeus_get_responses")
        #expect(poll["items"] == .array([]))
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        try await bridge.finish()
    }

    @Test func userMessageSentAckThinkingAndResponseEndThroughRealBridge() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try await f.bridge()
        #expect(await f.runtime.sendUserMessage("Please draft my presentation") == .delivered)
        let push = try await bridge.userMessage()
        #expect(push["content"] == "Message from the user: Please draft my presentation")
        let initial = try #require(f.runtime.assistantActivity)
        #expect(initial.phase == .sent && initial.sessionKey == f.key() && initial.agentName == "Claude")
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [try #require(push["meta"]?["delivery_id"])]])
        #expect(f.runtime.assistantActivity?.phase == .thinking && f.runtime.assistantActivity?.since == initial.since)
        _ = try await bridge.call("zeus_set_status", ["state": "working", "detail": "Drafting your Q3 talk", "progress": 0.25])
        #expect(f.runtime.assistantActivity?.phase == .working && f.runtime.assistantActivity?.detail == "Drafting your Q3 talk")
        #expect(f.runtime.assistantActivity?.progress == 0.25 && f.status.presentation.state == .working)
        let reply = try await bridge.call("zeus_say", ["text": "The outline is ready."])
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        let replyID = try e2eString(reply["card_id"])
        #expect(f.cards.card(id: replyID)?.body == "The outline is ready.")
        try await bridge.finish()
    }

    @Test func realBridgeActivityExpiresOnStaleTimeoutTTLAndDisconnect() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try await f.bridge()
        #expect(await f.runtime.sendUserMessage("Waiting for the agent") == .delivered)
        _ = try await bridge.userMessage()
        f.clock.advance(300)
        try await eventually { f.runtime.assistantActivity == nil }
        #expect(f.runtime.activityTimer == nil)
        _ = try await bridge.call("zeus_ack", ["delivery_ids": []])
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        #expect(await f.runtime.sendUserMessage("A new turn") == .delivered)
        let push = try await bridge.userMessage()
        _ = try await bridge.call("zeus_ack", ["delivery_ids": [try #require(push["meta"]?["delivery_id"])]])
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        f.clock.advance(300)
        try await eventually { f.runtime.assistantActivity == nil }
        _ = try await bridge.call("zeus_set_status", ["state": "working", "detail": "A brief task", "ttl_seconds": 10])
        #expect(f.runtime.assistantActivity?.phase == .working)
        f.clock.advance(10)
        try await eventually { f.runtime.assistantActivity == nil }
        _ = try await bridge.call("zeus_set_status", ["state": "working", "detail": "Another task"])
        bridge.kill()
        try await eventually { f.runtime.sessions.isEmpty && f.runtime.assistantActivity == nil }
        #expect(f.runtime.activityTimer == nil)
    }

    @Test func synchronousAskAnswerStartsSentWithoutChannelDuplication() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try await f.bridge()
        let id = try bridge.send(method: "tools/call", params: ["name": "zeus_ask", "arguments": ["text": "Start now?", "wait_seconds": 45]])
        try await eventually { f.runtime.waiters.count == 1 }
        #expect(f.runtime.assistantActivity == nil)
        let cardID = try #require(f.cards.cards.first?.id)
        try f.answer(cardID, text: "Yes")
        let answered = try await bridge.reply(to: id)
        #expect(answered["structuredContent"]?["status"] == "answered" && f.runtime.assistantActivity?.phase == .sent)
        #expect(f.runtime.ledger?.records.isEmpty == true)
        _ = try await bridge.call("zeus_list_characters")
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        _ = try await bridge.call("zeus_set_status", ["state": "auto"])
        #expect(f.runtime.assistantActivity == nil)
        try await bridge.finish()
        #expect(bridge.channels.isEmpty)
    }
}
