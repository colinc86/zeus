import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct DeliveryProblemTests {
    @Test func queuedReplyShowsOnlyAtFailureAndDismissalPersistsUntilANewFailure() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        _ = await f.call("zeus_ask", ["text": "Queued", "wait_seconds": 0])
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, text: "Reply")
        #expect(f.status.problem == nil)
        f.connect(); f.connector.fails = true
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.status.problem == nil)
        for seconds in [180.0, 360.0, 720.0, 1440.0] {
            let count = f.connector.deliveries.count
            f.clock.advance(seconds)
            try await eventually { f.connector.deliveries.count == count + 1 && f.runtime.sends.isEmpty }
            #expect(f.status.problem == (count == 4 ? ZeusRuntime.deliveryProblemText : nil))
        }
        f.status.setDeliveryProblem(nil) // Same seam call made by the UI's dismiss action.
        f.runtime.refreshProblem()
        f.clock.advance(10000)
        await Task.yield()
        #expect(f.status.problem == nil)
        var next = Delivery(id: "d_newfail1", kind: .reply, sessionKey: "claude:/assistant", content: "New failure", attempts: 5, failedAt: f.clock.now)
        next.meta = ["delivery_id": next.id, "kind": "reply"]
        try f.runtime.ledger?.insert(.init(delivery: next))
        f.runtime.refreshProblem()
        #expect(f.status.problem == ZeusRuntime.deliveryProblemText)
        let firstID = try #require(f.runtime.ledger?.records.first?.delivery.id)
        _ = await f.call("zeus_ack", ["delivery_ids": [.string(firstID)]])
        #expect(f.status.problem == ZeusRuntime.deliveryProblemText)
        _ = await f.call("zeus_get_responses")
        #expect(f.status.problem == nil)
    }

    @Test func pendingWarningsStartOnlyAfterTwoMinutesAndClearOnReachability() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        _ = await f.runtime.sendUserMessage("No assistant")
        #expect(f.status.problem == nil && f.runtime.deliveryIssue == nil)
        f.routing.assistantSessionKey = "claude:/assistant"
        _ = await f.runtime.sendUserMessage("Waiting")
        f.clock.advance(120)
        f.runtime.processDueDeliveries()
        #expect(f.status.problem == nil)
        f.clock.advance(0.01)
        try await eventually { f.runtime.deliveryIssue != nil }
        #expect(f.status.problem == ZeusRuntime.deliveryProblemText)
        #expect(f.runtime.deliveryIssue?.pendingCount == 2)
        #expect(f.runtime.deliveryIssue?.detail.contains("messages are saved") == true)
        f.connect("codex:/unrelated", channel: false, agent: .codex)
        #expect(f.runtime.deliveryIssue != nil && f.status.problem != nil)
        f.connect("claude:/assistant", channel: false)
        #expect(f.runtime.deliveryIssue == nil && f.status.problem == nil)
        // The selected live session can consume input by polling; unrelated sessions cannot.
        #expect(f.runtime.ledger?.records.first?.delivery.ackedAt == nil)
    }

    @Test func pollingIsQueueOnlyAndChangingSettingsFlushesPendingInput() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect()
        f.routing.deliveryMethod = .polling
        if case .queued = await f.runtime.sendUserMessage("Pull-only") { } else { Issue.record("Expected polling queue") }
        #expect(f.connector.deliveries.isEmpty)
        #expect(f.runtime.ledger?.records.first?.delivery.attempts == 0)
        #expect(f.status.problem == nil) // The connected pull-only session is reachable by polling.
        f.routing.deliveryMethod = .tmux
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
    }

    @Test func missingTmuxPaneIsRecordedAsAnAttemptAndReplyOriginKeepsItsKey() async throws {
        let directory = URL(fileURLWithPath: "/tmp/zp4_" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestRuntimeClock(), routing = FakeRouting(), runner = FakeProcessRunner()
        let cards = FakeCards(clock: clock), status = FakeStatus(), characters = FakeCharacters()
        routing.assistantSessionKey = "codex:/assistant"; routing.deliveryMethod = .tmux; routing.tmuxTarget = "%missing"
        await runner.fail(at: 2)
        let runtime = ZeusRuntime(cards: cards, status: status, characters: characters, routing: routing, clock: clock,
                                  socketPath: directory.appendingPathComponent("bridge.sock").path,
                                  ledgerURL: directory.appendingPathComponent("deliveries.json"),
                                  connectors: [TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)])
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(connectorSession())
        if case .queued = await runtime.sendUserMessage("Missing pane") { } else { Issue.record("Expected failed transport queue") }
        #expect(runtime.ledger?.records.first?.delivery.attempts == 1)
        #expect(runtime.ledger?.records.first?.delivery.failedAt == nil)
        #expect(status.problem == nil)
    }
}

extension DeliveryProblemTests {
    @Test func preferredAgentQueueIgnoresUnrelatedPollingSession() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.preferredAgent = .claude; f.routing.deliveryMethod = .polling
        f.connect("codex:/unrelated", channel: false, agent: .codex)
        _ = await f.runtime.sendUserMessage("Wait for Claude")
        f.clock.advance(121)
        f.runtime.processDueDeliveries()
        #expect(f.runtime.deliveryIssue?.pendingCount == 1)
        #expect(f.status.problem != nil)
        let poll = await f.call("zeus_get_responses", session: "codex:/unrelated")
        #expect(poll.structured?["items"] == .array([]))
        f.connect("claude:/ready", channel: false)
        #expect(f.runtime.deliveryIssue == nil && f.status.problem == nil)
        #expect(f.runtime.ledger?.records.first?.delivery.sessionKey == "claude:/ready")
    }
}
