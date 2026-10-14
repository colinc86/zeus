import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct AgentUXTests {
    private func disconnect(_ f: RuntimeFixture, key: String) throws {
        let session = try #require(f.runtime.sessions.first { $0.sessionKey == key })
        f.runtime.unregisterSession(id: session.id, sessionKey: key)
    }

    @Test func replyReroutesOnlyAfterSixtySecondsAndAssistantOwnsAck() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let origin = "claude:/one-shot", assistant = "codex:/assistant"
        f.routing.assistantSessionKey = assistant
        f.connect(origin); f.connect(assistant, channel: false, agent: .codex)
        _ = await f.call("zeus_ask", ["text": "Proceed?", "wait_seconds": 0], session: origin)
        let card = try #require(f.cards.values.first)
        try disconnect(f, key: origin)
        f.cards.respond(id: card.id, option: "yes", label: "Yes", text: "Please proceed")
        let id = try #require(f.runtime.ledger?.records.first?.delivery.id)
        f.clock.advance(60)
        f.runtime.processDueDeliveries()
        #expect(f.connector.deliveries.isEmpty)
        #expect(f.runtime.ledger?.record(id: id)?.delivery.sessionKey == origin)
        f.clock.advance(0.01)
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        let sent = try #require(f.connector.deliveries.first)
        #expect(sent.id == id && sent.cardID == card.id && sent.sessionKey == assistant)
        #expect(sent.content == "(Answer to a question from an earlier session) Reply to \"Proceed?\": Yes\nPlease proceed")
        #expect(sent.meta["option_id"] == "yes" && sent.meta["earlier_session"] == origin)
        let persisted = try #require(DeliveryLedger(location: f.runtime.ledgerURL).record(id: id)?.delivery)
        #expect(persisted.id == sent.id && persisted.sessionKey == sent.sessionKey)
        #expect(persisted.content == sent.content && persisted.meta == sent.meta)
        #expect(persisted.attempts == 1)
        // The contract's ISO8601 snapshots have millisecond precision.
        #expect(abs((persisted.lastAttemptAt ?? .distantPast).timeIntervalSince(sent.lastAttemptAt ?? .distantFuture)) < 0.0011)
        #expect(f.runtime.deliveryIssue == nil && f.status.problem == nil)
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]], session: origin)
        #expect(f.runtime.ledger?.record(id: id)?.delivery.ackedAt == nil)
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(id)]], session: assistant)
        #expect(f.runtime.ledger?.record(id: id)?.delivery.ackedAt != nil)
    }

    @Test func lateAnswerToDeadClaudePSessionDoesNotLeavePermanentWarning() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let origin = "claude:/dead-p", assistant = "opencode:/assistant"
        f.connect(origin)
        _ = await f.call("zeus_ask", ["text": "Old question", "wait_seconds": 0], session: origin)
        let card = try #require(f.cards.values.first)
        try disconnect(f, key: origin)
        f.clock.advance(3600)
        f.routing.assistantSessionKey = assistant
        f.connect(assistant, channel: false, agent: .opencode)
        f.cards.respond(id: card.id, text: "Late answer")
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries.first?.sessionKey == assistant)
        #expect(f.status.problem == nil && f.runtime.deliveryIssue == nil)
        _ = await f.call("zeus_get_responses", session: assistant)
        f.clock.advance(10000)
        f.runtime.processDueDeliveries()
        #expect(f.status.problem == nil && f.runtime.deliveryIssue == nil)
        #expect(f.connector.deliveries.count == 1)
    }

    @Test func orphanWarningResolvesWhenAnAssistantArrivesAndPollingGetsPrefix() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect("claude:/dead")
        _ = await f.call("zeus_ask", ["text": "Question", "wait_seconds": 0], session: "claude:/dead")
        let card = try #require(f.cards.values.first)
        try disconnect(f, key: "claude:/dead")
        f.cards.respond(id: card.id, text: "Answer")
        f.clock.advance(120)
        f.runtime.processDueDeliveries()
        #expect(f.runtime.deliveryIssue == nil)
        f.clock.advance(0.01)
        try await eventually { f.runtime.deliveryIssue != nil }
        f.routing.deliveryMethod = .polling
        f.connect("codex:/new", channel: false, agent: .codex)
        #expect(f.runtime.deliveryIssue == nil && f.status.problem == nil)
        #expect(f.connector.deliveries.isEmpty)
        let result = await f.call("zeus_get_responses", session: "codex:/new")
        #expect(result.structured?["items"]?[0]?["text"] == "(Answer to a question from an earlier session) Answer")
        #expect(result.structured?["items"]?[0]?["card_id"] == .string(card.id))
    }

    @Test func reconnectBeforeRerouteKeepsOriginalSessionAndResetsAbsenceWindow() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect("claude:/origin"); f.connect()
        f.routing.assistantSessionKey = "claude:/assistant"
        _ = await f.call("zeus_ask", ["text": "Question", "wait_seconds": 0], session: "claude:/origin")
        let card = try #require(f.cards.values.first)
        try disconnect(f, key: "claude:/origin")
        f.cards.respond(id: card.id, text: "Answer")
        f.clock.advance(59)
        f.connect("claude:/origin")
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries.first?.sessionKey == "claude:/origin")
        try disconnect(f, key: "claude:/origin")
        f.clock.advance(60)
        f.runtime.processDueDeliveries()
        #expect(f.runtime.ledger?.records.first?.delivery.sessionKey == "claude:/origin")
        f.clock.advance(0.01)
        try await eventually { f.connector.deliveries.count == 2 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries.last?.sessionKey == "claude:/assistant")
        #expect(f.connector.deliveries.last?.attempts == 1)
    }

    @Test func retryReopensExhaustedDeliveriesWithoutAcknowledgingThem() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let delivery = Delivery(kind: .userMessage, sessionKey: "claude:/assistant", content: "Saved", createdAt: f.clock.now,
                                attempts: 5, lastAttemptAt: f.clock.now, failedAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        f.runtime.refreshProblem()
        #expect(f.runtime.deliveryIssue?.pendingCount == 1)
        f.connect()
        #expect(f.connector.deliveries.isEmpty)
        f.runtime.retryPendingDeliveries()
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        let saved = try #require(DeliveryLedger(location: f.runtime.ledgerURL).record(id: delivery.id))
        #expect(saved.delivery.id == delivery.id && saved.delivery.attempts == 1)
        #expect(saved.delivery.failedAt == nil && saved.delivery.ackedAt == nil)
        #expect(f.runtime.deliveryIssue == nil && f.status.problem == nil)
    }

    @Test func retryBypassesBackoffAndDoesNotOverlapAnActiveSend() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect()
        _ = await f.runtime.sendUserMessage("Saved")
        f.connector.hold = true
        f.runtime.retryPendingDeliveries()
        try await eventually { f.connector.deliveries.count == 2 }
        f.runtime.retryPendingDeliveries()
        await Task.yield()
        #expect(f.connector.deliveries.count == 2 && f.runtime.sends.count == 1)
        f.connector.release()
        try await eventually { f.runtime.sends.isEmpty }
        #expect(f.runtime.ledger?.records.first?.delivery.ackedAt == nil)
    }

    @Test func discardMarksOnlyPendingAndLateCompletionCannotResurrectIt() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect()
        _ = await f.runtime.sendUserMessage("Handled")
        let handled = try #require(f.runtime.ledger?.records.first?.delivery.id)
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(handled)]])
        f.connector.hold = true
        let task = Task { await f.runtime.sendUserMessage("Discard me") }
        try await eventually { f.connector.deliveries.count == 2 }
        f.runtime.discardPendingDeliveries()
        #expect(f.runtime.ledger?.records.filter { $0.discardedAt == nil }.map { $0.delivery.id } == [handled])
        let discarded = try #require(f.runtime.ledger?.records.first { $0.discardedAt != nil })
        #expect(!discarded.isPending && discarded.delivery.ackedAt == nil)
        #expect(f.runtime.deliveryIssue == nil && f.status.problem == nil && f.runtime.sends.isEmpty)
        f.connector.release()
        _ = await task.value
        f.clock.advance(10000)
        f.runtime.processDueDeliveries()
        let persisted = try DeliveryLedger(location: f.runtime.ledgerURL)
        #expect(persisted.records.filter { $0.discardedAt == nil }.map { $0.delivery.id } == [handled])
        #expect(persisted.record(id: discarded.delivery.id)?.discardedAt == discarded.discardedAt)
        #expect(f.connector.deliveries.count == 2 && f.runtime.deliveryIssue == nil)
    }

    @Test func failedDiscardLeavesDurableItemsAndWarningIntact() throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let delivery = Delivery(kind: .reply, sessionKey: "offline", content: "Saved", createdAt: f.clock.now,
                                attempts: 5, failedAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        f.runtime.refreshProblem()
        try FileManager.default.removeItem(at: f.runtime.ledgerURL)
        try FileManager.default.createDirectory(at: f.runtime.ledgerURL, withIntermediateDirectories: true)
        f.runtime.discardPendingDeliveries()
        #expect(f.runtime.ledger?.records.count == 1)
        #expect(f.runtime.deliveryIssue != nil && f.status.problem != nil)
    }

    @Test func persistedDisconnectReroutesAfterRestartWithSameDeliveryID() async throws {
        let first = try RuntimeFixture(); defer { first.stop() }
        first.connect("claude:/old")
        _ = await first.call("zeus_ask", ["text": "Question", "wait_seconds": 0], session: "claude:/old")
        let card = try #require(first.cards.values.first)
        try disconnect(first, key: "claude:/old")
        first.cards.respond(id: card.id, text: "Answer")
        let id = try #require(first.runtime.ledger?.records.first?.delivery.id)
        first.stop(remove: false)
        let next = try RuntimeFixture(directory: first.directory); defer { next.stop() }
        next.clock.advance(61)
        next.connect("codex:/assistant", channel: false, agent: .codex)
        try await eventually { next.connector.deliveries.count == 1 && next.runtime.sends.isEmpty }
        #expect(next.connector.deliveries.first?.id == id)
        #expect(next.connector.deliveries.first?.sessionKey == "codex:/assistant")
    }

    @Test func shutdownPersistsFreshDisconnectTimeForAnOldPendingReply() async throws {
        let first = try RuntimeFixture(); defer { first.stop() }
        first.connect("claude:/origin")
        _ = await first.call("zeus_ask", ["text": "Question", "wait_seconds": 0], session: "claude:/origin")
        let card = try #require(first.cards.values.first)
        first.cards.respond(id: card.id, text: "Answer")
        try await eventually { first.connector.deliveries.count == 1 && first.runtime.sends.isEmpty }
        first.clock.advance(300, wake: false)
        first.stop(remove: false)
        let next = try RuntimeFixture(directory: first.directory); defer { next.stop() }
        next.clock.advance(300)
        next.connect("codex:/assistant", channel: false, agent: .codex)
        #expect(next.connector.deliveries.isEmpty)
        next.clock.advance(60)
        next.runtime.processDueDeliveries()
        #expect(next.runtime.ledger?.records.first?.delivery.sessionKey == "claude:/origin")
        next.clock.advance(0.01)
        try await eventually { next.connector.deliveries.count == 1 && next.runtime.sends.isEmpty }
        #expect(next.connector.deliveries.first?.sessionKey == "codex:/assistant")
    }

    @Test func autoRoutingIncludesNonChannelAgentsAndHonorsPreference() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect("codex:/older", channel: false, agent: .codex)
        #expect(f.runtime.assistantTarget == "codex:/older")
        f.connect("opencode:/newer", channel: false, agent: .opencode)
        #expect(f.runtime.assistantTarget == "opencode:/newer")
        f.connect("claude:/channel")
        f.connect("codex:/newest", channel: false, agent: .codex)
        #expect(f.runtime.assistantTarget == "claude:/channel")
        f.routing.preferredAgent = .codex
        #expect(f.runtime.assistantTarget == "codex:/newest")
        #expect(await f.runtime.sendUserMessage("Auto Codex") == .delivered)
        #expect(f.connector.deliveries.last?.sessionKey == "codex:/newest")
        f.routing.preferredAgent = .opencode
        #expect(await f.runtime.sendUserMessage("Auto OpenCode") == .delivered)
        #expect(f.connector.deliveries.last?.sessionKey == "opencode:/newer")
        f.routing.assistantSessionKey = "offline:explicit"
        #expect(f.runtime.assistantTarget == "offline:explicit")
    }

    @Test func changingAutoPreferenceReroutesAnOrphanWithoutAnotherConnection() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.preferredAgent = .claude
        f.connect("codex:/assistant", channel: false, agent: .codex)
        #expect(f.runtime.assistantTarget == nil)
        _ = await f.call("zeus_ask", ["text": "Question", "wait_seconds": 0], session: "claude:/old")
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, text: "Answer")
        f.clock.advance(61)
        f.runtime.processDueDeliveries()
        #expect(f.connector.deliveries.isEmpty)
        f.routing.preferredAgent = .codex
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries.first?.sessionKey == "codex:/assistant")
    }

    @Test func exhaustedOrphanGetsFreshAttemptsAndClearsItsWarningOnReroute() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let delivery = Delivery(kind: .reply, sessionKey: "claude:/dead", content: "Answer", createdAt: f.clock.now.addingTimeInterval(-3600),
                                attempts: 5, lastAttemptAt: f.clock.now, failedAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        f.runtime.processDueDeliveries()
        #expect(f.runtime.deliveryIssue != nil)
        f.connect("opencode:/assistant", channel: false, agent: .opencode)
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries.first?.attempts == 1)
        #expect(f.connector.deliveries.first?.id == delivery.id)
        #expect(f.runtime.deliveryIssue == nil && f.status.problem == nil)
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.failedAt == nil)
    }

    @Test func quietFlagReflectsCurrentHoursForImmediateDelayedAndErrorResults() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        #expect(await f.call("zeus_say", ["text": "Hello"]).structured?["quiet"] == nil)
        f.status.quiet = true
        let quiet = await f.call("zeus_list_characters")
        #expect(quiet.structured?["quiet"] == true)
        let invalid = await f.call("zeus_say", ["message": "Bad"])
        #expect(invalid.isError && invalid.structured?["quiet"] == true)
        f.status.quiet = false
        let task = Task { await f.call("zeus_ask", ["text": "Wait"]) }
        try await eventually { f.cards.values.count == 2 }
        f.status.quiet = true
        let question = try #require(f.cards.values.last)
        f.cards.respond(id: question.id, text: "Answered during quiet hours")
        #expect(await task.value.structured?["quiet"] == true)
        f.status.quiet = false
        #expect(await f.call("zeus_set_status", ["state": "sleeping"]).structured?["quiet"] == nil)
    }

    @Test func argumentErrorsNameKeysAndAttachmentsMustBeOpenable() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let error = await f.call("zeus_say", ["message": "Bad", "body": "Bad"])
        #expect(error.isError)
        #expect(error.structured?["error"] == "Unexpected arguments for zeus_say: body, message. Allowed: attachments, mood, priority, text, title, ttl_seconds.")
        for (kind, target) in [("file", "relative.txt"), ("folder", "./folder"), ("url", "file:///tmp/test"), ("url", "https:"), ("file", "/tmp/\0bad")] {
            let result = await f.call("zeus_say", ["text": "Bad", "attachments": [["kind": .string(kind), "label": "Open", "target": .string(target)]]])
            #expect(result.isError)
        }
        #expect(f.cards.values.isEmpty)
        for (kind, target) in [("file", "~/draft.txt"), ("folder", "/tmp/folder"), ("url", "https://example.com/report")] {
            #expect(await f.call("zeus_say", ["text": "Good", "attachments": [["kind": .string(kind), "label": "Open", "target": .string(target)]]]).isError == false)
        }
        for tool in ["zeus_update_card", "zeus_dismiss"] {
            let result = await f.call(tool, ["card_id": "c_missing"])
            #expect(result.structured?["ok"] == false)
            #expect(result.structured?["error"] == "No card c_missing (it may have been removed from history).")
        }
    }
}
