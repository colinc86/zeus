import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct SkippedResponseTests {
    /// Simulates appdev's transactional Skip callback without editing the UI store.
    private func skip(_ card: Card, in cards: FakeCards, at date: Date) {
        let response = CardResponse(respondedAt: date, device: .mac, skipped: true)
        _ = cards.update(id: card.id) { $0.status = .answered; $0.response = response }
        if let saved = cards.card(id: card.id) { cards.responseHandler?(saved, response) }
    }

    @Test func synchronousSkipClosesWaiterAndDoesNotReplayOnRestart() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect()
        f.cards.onAdd = { card in self.skip(card, in: f.cards, at: f.clock.now) }
        let result = await f.call("zeus_ask", ["text": "Should we continue?"])
        let card = try #require(f.cards.values.first)
        #expect(result.structured == ["status": "skipped", "card_id": .string(card.id)])
        #expect(card.status == .answered && card.response?.skipped == true)
        #expect(f.runtime.waiters.isEmpty && f.runtime.responseJournal?.intents.isEmpty == true)
        #expect(f.runtime.completedResponseIDs.contains(card.id))
        #expect(f.runtime.assistantActivity?.phase == .sent)
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.records.isEmpty == true && f.connector.deliveries.isEmpty)
    }

    @Test(arguments: [false, true])
    func synchronousSkipUsesResultConsumptionReceipt(written: Bool) async throws {
        let f = try RuntimeFixture(channelOnly: true); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/fixture",
            client: .init(name: "Skip receipt", version: "1"), capabilities: .init(toolResultWritten: true), parentStartTime: 34)
        do {
            _ = try await client.start(hello: hello, onPush: { _ in })
            let ask = Task { try await client.requestTool(name: "zeus_ask", arguments: ["text": "Receipt question"]) }
            try await eventually { f.runtime.waiters.count == 1 }
            let card = try #require(f.cards.values.first)
            let id = try #require(f.runtime.responseJournal?.intents.first?.deliveryID)
            skip(card, in: f.cards, at: f.clock.now)
            let reply = try await ask.value
            #expect(reply.structured == ["status": "skipped", "card_id": .string(card.id)])
            #expect(f.runtime.assistantActivity == nil && f.runtime.ledger?.records.isEmpty == true)
            #expect(f.runtime.awaitingAnswerReceipt.contains(card.id))
            if written {
                try await client.reportToolResultWritten(callID: reply.callID)
                try await eventually { f.runtime.responseJournal?.intents.isEmpty == true }
                #expect(f.runtime.assistantActivity?.phase == .sent)
                await client.stop()
                f.runtime.stop(); try f.runtime.start()
                #expect(f.runtime.ledger?.records.isEmpty == true)
            } else {
                await client.stop()
                try await eventually { f.runtime.ledger?.records.count == 1 }
                let recovered = try #require(f.runtime.ledger?.record(id: id))
                #expect(recovered.response?.skipped == true && recovered.delivery.meta["kind"] == "skipped")
                #expect(f.runtime.assistantActivity == nil && f.runtime.awaitingAnswerReceipt.isEmpty)
                f.runtime.stop(); try f.runtime.start()
                #expect(f.runtime.ledger?.records.count == 1 && f.runtime.ledger?.records.first?.delivery.id == id)
            }
        } catch { await client.stop(); throw error }
    }

    @Test func lateSkipChannelsToOriginAndAcknowledgesOnce() async throws {
        let f = try RuntimeFixture(channelOnly: true); defer { f.stop() }
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/origin",
            client: .init(name: "Skip channel", version: "1"), capabilities: .init(channel: true), parentStartTime: 34)
        var pushes: [AgentPush] = []
        do {
            _ = try await client.start(hello: hello, onPush: { push in
                await MainActor.run { pushes.append(push) }
                try? await client.reportPushWritten(deliveryID: push.deliveryID)
            })
            let pending = try await client.callTool(name: "zeus_ask", arguments: ["text": "Question body", "title": "Choose a path", "wait_seconds": 0])
            #expect(pending.structured?["status"] == "pending")
            let card = try #require(f.cards.values.first)
            skip(card, in: f.cards, at: f.clock.now)
            try await eventually { pushes.count == 1 && f.runtime.sends.isEmpty }
            let delivery = try #require(f.runtime.ledger?.records.first?.delivery)
            #expect(delivery.sessionKey == hello.sessionKey && delivery.kind == .reply)
            #expect(pushes.first == AgentPush(deliveryID: delivery.id, content: "The user skipped \"Choose a path\".",
                meta: ["kind": "skipped", "delivery_id": delivery.id, "card_id": card.id]))
            _ = try await client.callTool(name: "zeus_ack", arguments: ["delivery_ids": [.string(delivery.id)]])
            #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt != nil)
            skip(card, in: f.cards, at: f.clock.now) // A repeated callback cannot duplicate the answer.
            f.clock.advance(180); f.runtime.processDueDeliveries()
            #expect(pushes.count == 1 && f.runtime.ledger?.records.count == 1)
            await client.stop()
        } catch { await client.stop(); throw error }
    }

    @Test func lateSkipSurvivesRelaunchAndPollingReportsSkipped() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling; f.connect()
        _ = await f.call("zeus_ask", ["text": "No title here", "wait_seconds": 0])
        let card = try #require(f.cards.values.first)
        skip(card, in: f.cards, at: f.clock.now)
        let id = try #require(f.runtime.ledger?.records.first?.delivery.id)
        f.runtime.stop(); try f.runtime.start(); f.connect()
        let result = await f.call("zeus_get_responses")
        #expect(result.structured?["items"]?[0]?["kind"] == "skipped")
        #expect(result.structured?["items"]?[0]?["text"] == "The user skipped \"No title here\".")
        #expect(result.structured?["items"]?[0]?["delivery_id"] == .string(id))
        #expect(result.structured?["items"]?[0]?["card_id"] == .string(card.id))
        #expect(result.structured?["items"]?[0]?["option_id"] == nil && result.structured?["items"]?[0]?["option_label"] == nil)
        #expect(f.runtime.ledger?.record(id: id)?.response?.skipped == true)
        #expect(f.runtime.ledger?.record(id: id)?.delivery.ackedAt != nil)
        #expect(await f.call("zeus_get_responses").structured?["items"] == [])
    }

    @Test(arguments: [DeliveryMethod.tmux, .opencode])
    func textTransportsSendSkippedWordsInNormalEnvelope(method: DeliveryMethod) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.runtime.stop()
        let runner = FakeProcessRunner(), http = NativeOpenCodeHTTP()
        let session = connectorSession(agent: method == .opencode ? .opencode : .codex, pane: "%0")
        f.routing.deliveryMethod = method
        f.routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        f.routing.openCodeSessionIDs[session.sessionKey] = "ses_A"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing,
            clock: f.clock, socketPath: f.runtime.socketPath, ledgerURL: f.runtime.ledgerURL,
            connectors: [TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner), OpenCodeConnector(transport: http, credentials: { nil })],
            targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(session)
        _ = await runtime.callTool("zeus_ask", arguments: ["text": "Carry on?", "wait_seconds": 0], sessionKey: session.sessionKey)
        skip(try #require(f.cards.values.first), in: f.cards, at: f.clock.now)
        try await eventually { runtime.ledger?.records.first?.delivery.attempts == 1 && runtime.sends.isEmpty }
        let delivery = try #require(runtime.ledger?.records.first?.delivery)
        let expected = "[zeus delivery_id=\(delivery.id) card_id=\(delivery.cardID ?? "")] The user skipped \"Carry on?\". (call zeus_ack with this delivery_id)"
        #expect(delivery.meta["kind"] == "skipped")
        if method == .tmux {
            #expect(String(decoding: await runner.buffer, as: UTF8.self) == expected)
            #expect(await runner.calls.contains { $0.arguments.first == "send-keys" })
        } else {
            let saved = try #require(await http.saved.values.first)
            #expect(saved["parts"]?[0]?["text"] == .string(expected))
        }
        #expect(runtime.ledger?.records.first?.delivery.ackedAt == nil)
    }
}
