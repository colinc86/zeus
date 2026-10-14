import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct TurnEndedActivityTests {
    private let key = "claude:/assistant#17.100"
    private func event(_ f: RuntimeFixture, id: String? = nil, at: Date? = nil, reason: TurnEnded.Reason = .completed) -> TurnEnded {
        .init(agent: .claude, pid: 99, ppid: 18, cwd: "/assistant", ancestors: [.init(pid: 18, startTime: 200), .init(pid: 17, startTime: 100)],
              firedAt: (at ?? f.clock.now).timeIntervalSince1970, reason: reason, nativeSessionID: "native-fixture", deliveryID: id)
    }
    @Test(arguments: [TurnEnded.Reason.completed, .interrupted, .error, .sessionEnded, .idle])
    func endsImplicitButNeverExplicitTTL(_ reason: TurnEnded.Reason) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(key)
        #expect(await f.runtime.sendUserMessage("A", deliveryID: "d_hook_a") == .delivered)
        _ = await f.call("zeus_ack", ["delivery_ids": ["d_hook_a"]], session: key)
        await f.runtime.bridgeTurnEnded(event(f, id: "d_hook_a", reason: reason))
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        _ = await f.call("zeus_ack", ["delivery_ids": ["d_hook_a"]], session: key)
        #expect(f.runtime.assistantActivity == nil)
        _ = await f.call("zeus_set_status", ["state": "working", "ttl_seconds": 30], session: key)
        let deadline = f.runtime.activityRecords[key]?.deadline
        await f.runtime.bridgeTurnEnded(event(f, reason: reason))
        #expect(f.runtime.assistantActivity?.phase == .working && f.runtime.activityRecords[key]?.deadline == deadline)
        f.clock.advance(30)
        try await eventually { f.runtime.assistantActivity == nil }
    }
    @Test func exactParentLifetimeNotCwdPaneOrRecycledPID() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(key); f.connect("claude:/assistant#19.100")
        f.routing.assistantSessionKey = key
        #expect(await f.runtime.sendUserMessage("A") == .delivered)
        var wrong = event(f); wrong.ancestors = [.init(pid: 17, startTime: 101)]
        await f.runtime.bridgeTurnEnded(wrong)
        #expect(f.runtime.assistantActivity?.sessionKey == key)
        wrong = event(f); wrong.agent = .codex
        await f.runtime.bridgeTurnEnded(wrong)
        #expect(f.runtime.assistantActivity != nil)
        await f.runtime.bridgeTurnEnded(event(f))
        #expect(f.runtime.assistantActivity == nil)
        await f.runtime.bridgeTurnEnded(event(f)) // Unsolicited/duplicate cannot start anything.
        #expect(f.runtime.assistantActivity == nil)
    }
    @Test func newerResponseAfterFireOrAfterLeaseCannotBeCleared() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(key)
        #expect(await f.runtime.sendUserMessage("A", deliveryID: "d_hook_a") == .delivered)
        let old = event(f, id: "d_hook_a"), lease = try #require(f.runtime.prepareTurnEnded(old))
        // Same clock tick still gets a distinct response token.
        #expect(await f.runtime.sendUserMessage("B", deliveryID: "d_hook_b") == .delivered)
        f.runtime.finishTurnEnded(lease)
        #expect(f.runtime.activityRecords[key]?.deliveryID == "d_hook_b")
        f.clock.advance(1, wake: false)
        #expect(await f.runtime.sendUserMessage("C", deliveryID: "d_hook_c") == .delivered)
        #expect(f.runtime.prepareTurnEnded(old) == nil)
        var withoutID = old; withoutID.deliveryID = nil
        #expect(f.runtime.prepareTurnEnded(withoutID) == nil)
        #expect(f.runtime.activityRecords[key]?.deliveryID == "d_hook_c")
    }
    @Test func hookBeforeConnectorReceiptTombstonesOnlyTheCompletedInput() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(key); f.connector.hold = true
        let first = Task { await f.runtime.sendUserMessage("A", deliveryID: "d_hook_a") }
        try await eventually { f.connector.waits.count == 1 }
        await f.runtime.bridgeTurnEnded(event(f, id: "d_hook_a"))
        f.clock.advance(1, wake: false)
        let second = Task { await f.runtime.sendUserMessage("B", deliveryID: "d_hook_b") }
        try await eventually { f.connector.waits.count == 2 }
        f.connector.release()
        #expect(await first.value == .delivered)
        #expect(await second.value == .delivered)
        #expect(f.runtime.activityRecords[key]?.deliveryID == "d_hook_b")
    }
    @Test func delayedResultReceiptAndHookAreScopedToTheAnswer() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(key)
        // The actual sync-answer receipt is intentionally held until transport consumes the result.
        f.runtime.answerActivityReceipts["result"] = .init(sessionKey: key, deliveryID: "answer_hook", token: nil, sessionID: nil, receivedAt: f.clock.now)
        let lease = try #require(f.runtime.prepareTurnEnded(event(f)))
        f.runtime.noteDeliveredActivity(sessionKey: key, deliveryID: "answer_hook", inputStartedAt: f.clock.now)
        f.runtime.finishTurnEnded(lease)
        #expect(f.runtime.assistantActivity == nil)
        f.runtime.noteDeliveredActivity(sessionKey: key, deliveryID: "answer_hook")
        #expect(f.runtime.assistantActivity == nil)
    }
    @Test func oldHookDoesNotInvalidateNewerInFlightReceipt() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(key)
        #expect(await f.runtime.sendUserMessage("A", deliveryID: "d_hook_a") == .delivered)
        let lease = try #require(f.runtime.prepareTurnEnded(event(f, id: "d_hook_a")))
        f.connector.hold = true; f.clock.advance(1, wake: false)
        let next = Task { await f.runtime.sendUserMessage("B", deliveryID: "d_hook_b") }
        try await eventually { f.connector.waits.count == 1 }
        f.runtime.finishTurnEnded(lease)
        f.connector.release()
        #expect(await next.value == .delivered)
        #expect(f.runtime.activityRecords[key]?.deliveryID == "d_hook_b")
    }
    @Test func openCodeNativeConversationMismatchIsIgnored() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let key = "opencode:/assistant#17.100"; f.connect(key, agent: .opencode)
        f.routing.openCodeSessionIDs[key] = "session_current"
        #expect(await f.runtime.sendUserMessage("A") == .delivered)
        var signal = event(f); signal.agent = .opencode; signal.nativeSessionID = "session_other"
        await f.runtime.bridgeTurnEnded(signal)
        #expect(f.runtime.assistantActivity != nil)
        signal.nativeSessionID = "session_current"
        await f.runtime.bridgeTurnEnded(signal)
        #expect(f.runtime.assistantActivity == nil)
    }
}
