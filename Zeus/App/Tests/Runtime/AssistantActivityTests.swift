import Foundation
import Observation
import Synchronization
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct AssistantActivityTests {
    @Test func onlySuccessfulDeliveryStartsSentAndAckAdvancesToThinking() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        #expect(await f.runtime.sendUserMessage("Offline") != .delivered)
        #expect(f.runtime.assistantActivity == nil)
        f.connector.hold = true; f.connect()
        try await eventually { f.connector.waits.count == 1 }
        #expect(f.runtime.assistantActivity == nil)
        f.connector.release()
        try await eventually { f.runtime.assistantActivity?.phase == .sent }
        let initial = try #require(f.runtime.assistantActivity)
        #expect(initial.agentName == "Claude" && initial.sessionKey == "claude:/assistant")
        #expect(initial.detail == nil && initial.progress == nil)
        #expect(f.status.state == nil) // Rule 3b is read by A8, never a higher-priority override.
        let id = try #require(f.runtime.ledger?.records.first?.delivery.id)
        let changes = Mutex(0)
        withObservationTracking { _ = f.runtime.assistantActivity } onChange: { changes.withLock { $0 += 1 } }
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]])
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        #expect(f.runtime.assistantActivity?.since == initial.since && changes.withLock { $0 } == 1)
        let unchanged = Mutex(0)
        withObservationTracking { _ = f.runtime.assistantActivity } onChange: { unchanged.withLock { $0 += 1 } }
        _ = await f.call("zeus_list_characters")
        #expect(unchanged.withLock { $0 } == 0) // Heartbeats reset the deadline without UI clock publication.
    }

    @Test func failedInjectionAndQueuedPollingDoNotClaimDelivery() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect(); f.connector.fails = true
        #expect(await f.runtime.sendUserMessage("Try later") != .delivered)
        #expect(f.runtime.assistantActivity == nil)
        f.routing.deliveryMethod = .polling
        #expect(await f.runtime.sendUserMessage("Pull this") != .delivered)
        #expect(f.runtime.assistantActivity == nil)
        _ = await f.call("zeus_get_responses")
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        #expect(f.runtime.ledger?.records.allSatisfy { $0.delivery.ackedAt != nil } == true)
    }

    @Test func synchronousAndPendingAskAnswersStartActivityThroughTheirOwnPaths() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        let asking = Task { await f.call("zeus_ask", ["text": "Now?", "wait_seconds": 45]) }
        try await eventually { f.runtime.waiters.count == 1 }
        #expect(f.runtime.assistantActivity == nil) // Posting a question ends the previous activity immediately.
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, text: "Yes")
        #expect(await asking.value.structured?["status"] == "answered")
        #expect(f.runtime.assistantActivity?.phase == .sent && f.runtime.ledger?.records.isEmpty == true)
        let pending = await f.call("zeus_ask", ["text": "Later?", "wait_seconds": 0])
        #expect(f.runtime.assistantActivity == nil)
        let pendingID = try e2eString(pending.structured?["card_id"])
        f.cards.respond(id: pendingID, text: "Later answer")
        try await eventually { f.runtime.sends.isEmpty && f.runtime.assistantActivity?.phase == .sent }
        #expect(f.runtime.ledger?.records.count == 1)
    }

    @Test func sentAndThinkingExpireAtFiveMinutesAndToolHeartbeatResetsOnlyThinking() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Start") == .delivered)
        f.clock.advance(299, wake: false)
        #expect(f.runtime.assistantActivity?.phase == .sent)
        f.clock.advance(1)
        try await eventually { f.runtime.assistantActivity == nil }
        #expect(f.runtime.activityTimer == nil)
        _ = await f.call("zeus_list_characters")
        #expect(f.runtime.assistantActivity == nil)
        #expect(await f.runtime.sendUserMessage("New input") == .delivered)
        _ = await f.call("zeus_list_characters")
        let since = try #require(f.runtime.assistantActivity?.since)
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        f.clock.advance(299)
        _ = await f.call("zeus_list_characters")
        #expect(f.runtime.assistantActivity?.since == since)
        f.clock.advance(1)
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        f.clock.advance(299)
        try await eventually { f.runtime.assistantActivity == nil }
    }

    @Test(arguments: ["thinking", "working"])
    func explicitWorkStartsUnsolicitedCarriesDetailAndUsesTTL(_ state: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        _ = await f.call("zeus_set_status", ["state": .string(state), "detail": "Drafting your Q3 talk", "progress": 0.4, "ttl_seconds": 600])
        #expect(f.runtime.assistantActivity?.phase == .working)
        #expect(f.runtime.assistantActivity?.detail == "Drafting your Q3 talk" && f.runtime.assistantActivity?.progress == 0.4)
        #expect(f.status.state?.rawValue == state)
        f.clock.advance(599)
        _ = await f.call("zeus_list_characters")
        #expect(f.runtime.assistantActivity?.phase == .working) // No 5-minute timeout, and no TTL extension.
        f.clock.advance(1)
        try await eventually { f.runtime.assistantActivity == nil }
        _ = await f.call("zeus_set_status", ["state": "working", "ttl_seconds": 0])
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
    }

    @Test(arguments: ["auto", "idle", "talking", "alert", "waiting", "happy", "sleeping"])
    func otherStatusStatesEndActivity(_ state: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        _ = await f.call("zeus_set_status", ["state": "working"])
        _ = await f.call("zeus_set_status", ["state": .string(state)])
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
    }

    @Test(arguments: ["zeus_say", "zeus_ask", "zeus_present"])
    func actualNewCardPostsEndActivityButInvalidPostsDoNot(_ tool: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        _ = await f.call("zeus_set_status", ["state": "working"])
        let error = await f.call(tool)
        #expect(error.isError && f.runtime.assistantActivity?.phase == .working)
        let args: JSONValue = switch tool {
        case "zeus_present": ["title": "Done", "body": "Finished work"]
        case "zeus_ask": ["text": "Next?", "wait_seconds": 0]
        default: ["text": "Finished work"]
        }
        _ = await f.call(tool, args)
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
    }

    @Test func mostRecentlyStartedWinsEvenForEqualTimesAndOlderWorkCanResume() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect("claude:/a"); f.connect("opencode:/b", agent: .opencode)
        f.routing.assistantSessionKey = "claude:/a"
        #expect(await f.runtime.sendUserMessage("A") == .delivered)
        f.routing.assistantSessionKey = "opencode:/b"
        #expect(await f.runtime.sendUserMessage("B") == .delivered)
        #expect(f.runtime.assistantActivity?.sessionKey == "opencode:/b" && f.runtime.assistantActivity?.agentName == "OpenCode")
        _ = await f.call("zeus_list_characters", session: "claude:/a")
        #expect(f.runtime.assistantActivity?.sessionKey == "opencode:/b") // Updating an old start doesn't steal the row.
        _ = await f.call("zeus_say", ["text": "B done"], session: "opencode:/b")
        #expect(f.runtime.assistantActivity?.sessionKey == "claude:/a" && f.runtime.assistantActivity?.phase == .thinking)
        f.routing.assistantSessionKey = "opencode:/b"
        #expect(await f.runtime.sendUserMessage("B again") == .delivered)
        let b = try #require(f.runtime.sessions.first { $0.sessionKey == "opencode:/b" })
        f.runtime.unregisterSession(id: b.id, sessionKey: b.sessionKey)
        #expect(f.runtime.assistantActivity?.sessionKey == "claude:/a")
        f.runtime.stop()
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        try f.runtime.start()
        #expect(f.runtime.assistantActivity == nil)
    }

    @Test func discardEndsDeliveredInputButPreservesUnrelatedUnsolicitedWork() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Discard me") == .delivered)
        f.runtime.discardPendingDeliveries()
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        _ = await f.call("zeus_set_status", ["state": "working"])
        f.runtime.discardPendingDeliveries()
        #expect(f.runtime.assistantActivity?.phase == .working)
    }

    @Test func redeliveryDoesNotRestartAnEndedResponseOrDowngradeThinking() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Only one turn") == .delivered)
        _ = await f.call("zeus_list_characters")
        let thinking = f.runtime.assistantActivity
        f.runtime.retryPendingDeliveries()
        try await eventually { f.runtime.sends.isEmpty }
        #expect(f.runtime.assistantActivity == thinking)
        _ = await f.call("zeus_say", ["text": "Done"])
        f.runtime.retryPendingDeliveries()
        try await eventually { f.runtime.sends.isEmpty }
        #expect(f.runtime.assistantActivity == nil)
    }

    @Test(arguments: [true, false])
    func finalCardEndsActivityRegardlessOfAckOrder(_ sayFirst: Bool) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Handled input") == .delivered)
        let id = try #require(f.runtime.ledger?.records.first?.delivery.id)
        if sayFirst { _ = await f.call("zeus_say", ["text": "Finished"]) }
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]])
        if !sayFirst {
            #expect(f.runtime.assistantActivity?.phase == .thinking)
            _ = await f.call("zeus_say", ["text": "Finished"])
        }
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        // Neither a duplicate ack nor polling/ordinary traffic may reopen a completed turn.
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]])
        _ = await f.call("zeus_get_responses")
        _ = await f.call("zeus_list_characters")
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
    }

    @Test func getResponsesAfterSayAcknowledgesInputWithoutRestartingActivity() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Handled input") == .delivered)
        _ = await f.call("zeus_say", ["text": "Finished"])
        let result = await f.call("zeus_get_responses")
        #expect(result.structured?["items"]?[0] != nil && result.structured?["items"]?[1] == nil)
        #expect(f.runtime.ledger?.records.first?.delivery.ackedAt != nil)
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
    }

    @Test(arguments: [true, false])
    func replyBeforeTransportReceiptCannotBeResurrectedByEarlyAck(_ ackFirst: Bool) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(); f.connector.hold = true
        let sending = Task { await f.runtime.sendUserMessage("Receipt race") }
        try await eventually { f.connector.waits.count == 1 }
        let id = try #require(f.connector.deliveries.first?.id)
        if ackFirst { _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]]) }
        _ = await f.call("zeus_say", ["text": "Already finished"])
        if !ackFirst { _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]]) }
        #expect(f.runtime.assistantActivity == nil)
        f.connector.release()
        #expect(await sending.value == .delivered)
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
        #expect(f.runtime.activityEarlyAcknowledgments.isEmpty)
    }

    @Test func earlyAckReceiptStartsThinkingThenSayEndsIt() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(); f.connector.hold = true
        let sending = Task { await f.runtime.sendUserMessage("Receipt race") }
        try await eventually { f.connector.waits.count == 1 }
        let id = try #require(f.connector.deliveries.first?.id)
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]])
        #expect(f.runtime.assistantActivity == nil)
        f.clock.advance(10, wake: false)
        f.connector.release()
        #expect(await sending.value == .delivered)
        #expect(f.runtime.assistantActivity?.phase == .thinking)
        #expect(f.runtime.activityRecords["claude:/assistant"]?.deadline == f.clock.now.addingTimeInterval(290))
        _ = await f.call("zeus_say", ["text": "Finished"])
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]])
        #expect(f.runtime.assistantActivity == nil && f.runtime.activityTimer == nil)
    }

    @Test func oldAckDoesNotMarkADifferentInFlightInputAsThinking() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Old input") == .delivered)
        let oldID = try #require(f.connector.deliveries.first?.id)
        _ = await f.call("zeus_say", ["text": "Finished"])
        f.connector.hold = true
        let sending = Task { await f.runtime.sendUserMessage("New input") }
        try await eventually { f.connector.waits.count == 1 }
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(oldID)]])
        #expect(f.runtime.assistantActivity == nil)
        f.connector.release()
        #expect(await sending.value == .delivered)
        #expect(f.runtime.assistantActivity?.phase == .sent)
    }

    @Test func replacementAndRestartCannotKeepOldActivityOrTimersAlive() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Old connection") == .delivered)
        let oldID = try #require(f.runtime.sessions.first?.id)
        f.connect()
        #expect(f.runtime.assistantActivity == nil)
        _ = await f.call("zeus_set_status", ["state": "working"])
        f.runtime.unregisterSession(id: oldID, sessionKey: "claude:/assistant")
        #expect(f.runtime.assistantActivity?.phase == .working)
        f.clock.advance(50)
        f.runtime.stop(); try f.runtime.start(); f.connect()
        _ = await f.call("zeus_set_status", ["state": "working", "ttl_seconds": 600])
        let work = f.runtime.assistantActivity
        f.clock.advance(250)
        _ = await f.call("zeus_list_characters")
        #expect(f.runtime.assistantActivity == work)
    }

    @Test func failedDiscardDoesNotClearActivityBeforeDurableTombstone() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect()
        #expect(await f.runtime.sendUserMessage("Keep until discard saves") == .delivered)
        let activity = f.runtime.assistantActivity
        try FileManager.default.removeItem(at: f.runtime.ledgerURL)
        try FileManager.default.createDirectory(at: f.runtime.ledgerURL, withIntermediateDirectories: false)
        f.runtime.discardPendingDeliveries()
        #expect(f.runtime.assistantActivity == activity && f.runtime.ledger?.records.count == 1)
        try FileManager.default.removeItem(at: f.runtime.ledgerURL)
        f.runtime.discardPendingDeliveries()
        #expect(f.runtime.assistantActivity == nil && f.runtime.ledger?.records.first?.discardedAt != nil)
        #expect(f.runtime.ledger?.records.first?.delivery.ackedAt == nil)
    }

    @Test(arguments: ["zeus_set_status", "zeus_say", "auto", "discard", "disconnect"])
    func lateTransportReceiptCannotOverwriteLaterAgentActivity(_ event: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }; f.connect(); f.connector.hold = true
        let sending = Task { await f.runtime.sendUserMessage("Receipt race") }
        try await eventually { f.connector.waits.count == 1 }
        switch event {
        case "zeus_set_status": _ = await f.call(event, ["state": "working", "detail": "Already working"])
        case "zeus_say": _ = await f.call(event, ["text": "Already finished"])
        case "auto": _ = await f.call("zeus_set_status", ["state": "auto"])
        case "discard": f.runtime.discardPendingDeliveries()
        default:
            let session = try #require(f.runtime.sessions.first)
            f.runtime.unregisterSession(id: session.id, sessionKey: session.sessionKey)
        }
        let newer = f.runtime.assistantActivity
        f.connector.release()
        _ = await sending.value
        #expect(f.runtime.assistantActivity == newer)
        if event == "zeus_set_status" { #expect(newer?.phase == .working) }
        else { #expect(newer == nil) }
    }
}
