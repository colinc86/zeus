import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct RuntimeIntegrationTests {
    @Test func realChannelBridgeDeliversLateAnswerAndReconnectsToOrigin() async throws {
        let f = try RuntimeFixture(channelOnly: true)
        defer { f.stop() }
        let first = BridgeClient(socketPath: f.runtime.socketPath)
        let second = BridgeClient(socketPath: f.runtime.socketPath)
        var pushes: [AgentPush] = []
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 45, cwd: "/assistant", client: .init(name: "Integration", version: "1"), capabilities: .init(channel: true), parentStartTime: 123)
        do {
            _ = try await first.start(hello: hello, onPush: { push in
                await MainActor.run { pushes.append(push) }
                try? await first.reportPushWritten(deliveryID: push.deliveryID)
            })
            try await eventually { f.runtime.sessions.count == 1 }
            #expect(f.runtime.sessions.first?.clientName == "Integration")
            let originalConnection = try #require(f.runtime.bridges[hello.sessionKey])
            _ = try await first.callTool(name: "zeus_ask", arguments: ["text": "Have you started?", "wait_seconds": 0])
            let card = try #require(f.cards.values.first)
            f.cards.respond(id: card.id, option: "no", label: "No", text: "I haven't.")
            try await eventually { pushes.count == 1 && f.runtime.sends.isEmpty }
            let record = try #require(f.runtime.ledger?.records.first)
            #expect(pushes.first == AgentPush(deliveryID: record.delivery.id, content: "Reply to \"Have you started?\": No\nI haven't.",
                meta: ["kind": "reply", "delivery_id": record.delivery.id, "card_id": card.id, "option_id": "no"]))
            #expect(record.delivery.ackedAt == nil)
            _ = try await first.callTool(name: "zeus_ack", arguments: ["delivery_ids": [.string(record.delivery.id)]])
            #expect(f.runtime.ledger?.record(id: record.delivery.id)?.delivery.ackedAt != nil)
            _ = try await first.callTool(name: "zeus_present", arguments: ["title": "Draft", "body": "Done", "actions": [["id": "revise", "label": "Revise"]]])
            let content = try #require(f.cards.values.last)
            await first.stop()
            try await eventually { f.runtime.sessions.isEmpty }
            f.cards.respond(id: content.id, option: "revise", label: "Revise")
            let queued = try #require(f.runtime.ledger?.records.last)
            #expect(queued.delivery.attempts == 0 && queued.delivery.sessionKey == hello.sessionKey)
            let newHello = BridgeHello(bridgeID: hello.bridgeID, agent: .claude, pid: 1, ppid: 45, cwd: "/assistant", client: hello.client, capabilities: hello.capabilities, parentStartTime: 123)
            _ = try await second.start(hello: newHello, onPush: { push in
                await MainActor.run { pushes.append(push) }
                try? await second.reportPushWritten(deliveryID: push.deliveryID)
            })
            try await eventually { pushes.count == 2 && f.runtime.sends.isEmpty }
            #expect(pushes.last?.deliveryID == queued.delivery.id)
            #expect(f.runtime.sessions.first?.id == newHello.bridgeID)
            f.runtime.bridgeDidDisconnect(originalConnection)
            #expect(f.runtime.sessions.count == 1)
            #expect(f.runtime.ledger?.record(id: queued.delivery.id)?.delivery.ackedAt == nil)
            await second.stop()
        } catch { await first.stop(); await second.stop(); throw error }
    }

    @Test func unwriteableLedgerNeverSendsAndRecordedAnswerRetriesSaving() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect()
        try FileManager.default.createDirectory(at: f.runtime.ledgerURL, withIntermediateDirectories: true)
        if case .failed = await f.runtime.sendUserMessage("Can't save") { } else { Issue.record("Expected a persistence failure") }
        #expect(f.connector.deliveries.isEmpty && f.status.problem == nil)
        _ = await f.call("zeus_ask", ["text": "Keep my answer", "wait_seconds": 0])
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, text: "Do not lose me")
        #expect(f.runtime.unsaved.count == 1 && f.connector.deliveries.isEmpty)
        try FileManager.default.removeItem(at: f.runtime.ledgerURL)
        f.clock.advance(3)
        try await eventually { f.runtime.unsaved.isEmpty && f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.runtime.ledger?.records.first?.response?.text == "Do not lose me")
        #expect(f.status.problem == nil)
        _ = await f.call("zeus_get_responses")
        #expect(f.status.problem == nil)
    }

    @Test func corruptLedgerAndOccupiedSocketFailWithoutReplacingFiles() throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let other = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
                                socketPath: f.runtime.socketPath, ledgerURL: f.runtime.ledgerURL)
        #expect(throws: BridgeLinkError.socketAlreadyExists) { try other.start() }
        f.runtime.stop()
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: f.runtime.ledgerURL)
        #expect(throws: (any Error).self) { try other.start() }
        #expect(try Data(contentsOf: f.runtime.ledgerURL) == corrupt)
        #expect(!other.running)
    }

    @Test func stoppingRuntimeResolvesWaitersAndRejectsFurtherMessages() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let task = Task { await f.call("zeus_ask", ["text": "Stop me"]) }
        try await eventually { f.cards.values.count == 1 }
        f.runtime.stop()
        #expect(await task.value.structured?["status"] == "pending")
        #expect(f.runtime.waiters.isEmpty)
        #expect(await f.runtime.sendUserMessage("Hi") == .failed(reason: "Zeus runtime isn't running."))
    }

    @Test func legacyReplyUsesEarlierSessionReroutingWithoutGuessingAnAgentPID() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling; f.connect()
        _ = await f.call("zeus_ask", ["text": "Legacy question", "wait_seconds": 0])
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, text: "Saved answer")
        let original = try #require(f.runtime.ledger?.records.first?.delivery)
        f.runtime.stop(); try f.runtime.start()
        let processKey = "claude:/assistant#123.456"
        f.connect(processKey)
        #expect(f.runtime.ledger?.records.first?.delivery.sessionKey == original.sessionKey)
        f.clock.advance(61)
        f.runtime.processDueDeliveries()
        let rerouted = try #require(f.runtime.ledger?.records.first?.delivery)
        #expect(rerouted.id == original.id && rerouted.sessionKey == processKey)
        #expect(rerouted.meta["earlier_session"] == original.sessionKey && rerouted.ackedAt == nil)
        #expect(f.cards.values.first?.sessionKey == original.sessionKey)
    }
}
