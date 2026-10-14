import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct RuntimeDurabilityTests {
    @Test func answerSavedBeforeFailedLedgerRecoversInFreshRuntimeWithSameID() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let storeURL = f.directory.appendingPathComponent("cards.json")
        let store = CardStore(fileURL: storeURL)
        func runtime(_ cards: CardStore) -> ZeusRuntime {
            ZeusRuntime(cards: cards, status: f.status, characters: f.characters, routing: f.routing,
                        clock: f.clock, socketPath: f.directory.appendingPathComponent("real.sock").path,
                        ledgerURL: f.directory.appendingPathComponent("real-ledger.json"), connectors: [], targetIsDead: { _ in false })
        }
        let first = runtime(store); try first.start()
        _ = await first.callTool("zeus_ask", arguments: ["text": "Persist me", "wait_seconds": 0], sessionKey: "claude:/old")
        let card = try #require(store.cards.first)
        let id = try #require(first.responseJournal?.intents.first?.deliveryID)
        #expect(id.hasPrefix("d_") && id.count == 10)
        try FileManager.default.createDirectory(at: first.ledgerURL, withIntermediateDirectories: true)
        #expect(store.respond(id: card.id, response: .init(text: "Durable answer", respondedAt: f.clock.now, device: .mac)))
        #expect(first.unsaved.count == 1)
        first.stop()
        try FileManager.default.removeItem(at: first.ledgerURL)
        let restored = CardStore(fileURL: storeURL)
        let second = runtime(restored); try second.start(); defer { second.stop() }
        #expect(second.ledger?.record(id: id)?.response?.text == "Durable answer")
        #expect(second.responseJournal?.intents.isEmpty == true)
        second.stop(); try second.start()
        #expect(second.ledger?.records.count == 1)
    }

    @Test func responseCallbackCrashGapAndSynchronousAnswerDisposition() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        _ = await f.call("zeus_ask", ["text": "Gap", "wait_seconds": 0])
        let card = try #require(f.cards.values.first)
        f.cards.responseHandler = nil // Saved answer, killed before runtime callback.
        f.cards.respond(id: card.id, text: "Recover this")
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.records.first?.response?.text == "Recover this")
        f.cards.onAdd = { card in f.cards.respond(id: card.id, text: "Direct answer") }
        #expect(await f.call("zeus_ask", ["text": "Sync"]).structured?["status"] == "answered")
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.records.count == 1) // Direct answer never replayed.
    }

    @Test func pollingBatchesLargeEscapedAnswersAndRetainsSingleOversizedItem() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let text = String(repeating: "\"\\🐈\n", count: 15_000)
        for _ in 0..<30 {
            let d = Delivery(kind: .userMessage, sessionKey: "claude:/assistant", content: text, createdAt: f.clock.now)
            try f.runtime.ledger?.insert(.init(delivery: d, userText: text))
        }
        var returned: Set<String> = []; var batches = 0
        while returned.count < 30 {
            let poll = await f.call("zeus_get_responses")
            guard case .array(let items) = poll.structured?["items"] else { Issue.record("Missing items"); return }
            #expect(!items.isEmpty && !poll.isError)
            let frame = try ZeusJSON.encoder().encode(WireMessage.toolResult(.init(callID: UUID().uuidString, result: poll)))
            #expect(frame.count < 4 * 1024 * 1024)
            for item in items { if case .string(let id) = item["delivery_id"] { #expect(returned.insert(id).inserted) } }
            batches += 1
        }
        #expect(batches > 1)
        let huge = Delivery(kind: .userMessage, sessionKey: "claude:/assistant", content: String(repeating: "x", count: 3_000_000), createdAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: huge))
        #expect(await f.call("zeus_get_responses").isError)
        #expect(f.runtime.ledger?.record(id: huge.id)?.delivery.ackedAt == nil)
    }

    @Test func pollingResultIsNotAckedUntilReceiptAndDisconnectReplays() async throws {
        let f = try RuntimeFixture(channelOnly: true); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/same", client: .init(name: "Receipt", version: "1"),
                                capabilities: .init(toolResultWritten: true), parentStartTime: 34)
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        _ = try await client.start(hello: hello, onPush: { _ in })
        let d = Delivery(kind: .userMessage, sessionKey: hello.sessionKey, content: "Keep", createdAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: d))
        let result = try await client.requestTool(name: "zeus_get_responses")
        #expect(result.structured?["items"]?[0]?["delivery_id"] == .string(d.id))
        #expect(f.runtime.ledger?.record(id: d.id)?.delivery.ackedAt == nil)
        await client.stop()
        try await eventually { f.runtime.sessions.isEmpty }
        let retry = BridgeClient(socketPath: f.runtime.socketPath)
        _ = try await retry.start(hello: hello, onPush: { _ in })
        let replay = try await retry.requestTool(name: "zeus_get_responses")
        #expect(replay.structured == result.structured)
        try await retry.reportToolResultWritten(callID: replay.callID)
        try await eventually { f.runtime.ledger?.record(id: d.id)?.delivery.ackedAt != nil }
        await retry.stop()
    }

    @Test func cardWriteFailuresAreToolErrorsAndCorruptDataIsPreserved() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let path = f.directory.appendingPathComponent("corrupt-cards.json")
        let corrupt = Data("broken".utf8); try corrupt.write(to: path)
        let store = CardStore(fileURL: path)
        let runtime = ZeusRuntime(cards: store, status: f.status, characters: f.characters, routing: f.routing,
                                  socketPath: f.directory.appendingPathComponent("corrupt.sock").path,
                                  ledgerURL: f.directory.appendingPathComponent("other-ledger.json"))
        try runtime.start(); defer { runtime.stop() }
        let mutations: [(String, JSONValue)] = [("zeus_say", ["text": "Do not pretend"]), ("zeus_ask", ["text": "Question"]), ("zeus_present", ["title": "Title", "body": "Body"]), ("zeus_update_card", ["card_id": "c_missing"]), ("zeus_dismiss", ["card_id": "c_missing"])]
        for (name, args) in mutations {
            #expect(await runtime.callTool(name, arguments: args, sessionKey: "claude:/folder").isError)
        }
        let preserved = try Data(contentsOf: path)
        #expect(store.cards.isEmpty && preserved == corrupt)
        try FileManager.default.removeItem(at: path)
        let writable = CardStore(fileURL: path)
        let next = ZeusRuntime(cards: writable, status: f.status, characters: f.characters, routing: f.routing,
                               socketPath: f.directory.appendingPathComponent("write.sock").path,
                               ledgerURL: f.directory.appendingPathComponent("write-ledger.json"))
        try next.start(); defer { next.stop() }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        #expect(await next.callTool("zeus_say", arguments: ["text": "Blocked write"], sessionKey: "claude:/folder").isError)
    }

    @Test func deadModernUserTargetRetargetsButLiveParentOutageDoesNot() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
                                  socketPath: f.directory.appendingPathComponent("dead.sock").path,
                                  ledgerURL: f.directory.appendingPathComponent("dead-ledger.json"), connectors: [],
                                  targetIsDead: { $0 == "claude:/dead#123.456" })
        try runtime.start(); defer { runtime.stop() }
        let dead = Delivery(kind: .userMessage, sessionKey: "claude:/dead#123.456", content: "Keep identity", createdAt: f.clock.now, attempts: 5, failedAt: f.clock.now)
        let alive = Delivery(kind: .userMessage, sessionKey: "claude:/alive#321.654", content: "Wait for helper", createdAt: f.clock.now)
        try runtime.ledger?.insert(.init(delivery: dead, userText: "Keep identity")); try runtime.ledger?.insert(.init(delivery: alive))
        f.routing.assistantSessionKey = "claude:/new#987.654"
        runtime.processDueDeliveries()
        let moved = try #require(runtime.ledger?.record(id: dead.id))
        #expect(moved.delivery.sessionKey == f.routing.assistantSessionKey && moved.delivery.id == dead.id)
        #expect(moved.delivery.attempts == 0 && moved.delivery.failedAt == nil && moved.userText == "Keep identity")
        #expect(runtime.ledger?.record(id: alive.id)?.delivery == alive)
        #expect(try DeliveryLedger(location: runtime.ledgerURL).record(id: dead.id) == moved)
    }
    @Test func unflushedSynchronousAnswerBecomesDurableReplyAndDiscardDoesNotRecoverIt() async throws {
        let f = try RuntimeFixture(channelOnly: true); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/same", client: .init(name: "Receipt", version: "1"),
                                capabilities: .init(toolResultWritten: true), parentStartTime: 34)
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        _ = try await client.start(hello: hello, onPush: { _ in })
        let ask = Task { try await client.requestTool(name: "zeus_ask", arguments: ["text": "Sync receipt"]) }
        try await eventually { f.cards.values.count == 1 }
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, text: "Not flushed")
        #expect(try await ask.value.structured?["status"] == "answered")
        #expect(f.runtime.ledger?.records.isEmpty == true)
        #expect(f.runtime.responseJournal?.intents.count == 1)
        await client.stop()
        try await eventually { f.runtime.ledger?.records.count == 1 }
        #expect(f.runtime.ledger?.records.first?.response?.text == "Not flushed")
        f.runtime.discardPendingDeliveries()
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.records.isEmpty == true && f.runtime.responseJournal?.intents.isEmpty == true)
    }

    @Test func lostSynchronousReceiptAfterAgentReplyDoesNotRestartActivity() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/same", client: .init(name: "Receipt", version: "1"),
                                capabilities: .init(toolResultWritten: true), parentStartTime: 34)
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        _ = try await client.start(hello: hello, onPush: { _ in })
        let ask = Task { try await client.requestTool(name: "zeus_ask", arguments: ["text": "Answer once"]) }
        try await eventually { f.cards.values.count == 1 }
        let card = try #require(f.cards.values.first)
        let intentID = try #require(f.runtime.responseJournal?.intents.first?.deliveryID)
        f.cards.respond(id: card.id, text: "Answer")
        let answered = try await ask.value
        #expect(f.runtime.assistantActivity == nil)
        #expect(f.runtime.answerActivityReceipts[card.id]?.deliveryID == intentID)
        _ = try await client.requestTool(name: "zeus_say", arguments: ["text": "Finished"])
        #expect(f.runtime.assistantActivity == nil)
        let session = try #require(f.runtime.bridges[hello.sessionKey])
        // The result was read but its stdout receipt was lost. Recovery must reuse
        // the activity identity, even if it has to replay the durable answer.
        f.runtime.bridge(session, finishedTool: "zeus_ask", result: answered.result, written: false)
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.connector.deliveries.first?.id == intentID)
        #expect(f.runtime.assistantActivity == nil)
        await client.stop()
    }

    @Test func stoppedRuntimeReceiptsCannotOverwriteReplacementLedgerOrJournal() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/same", client: .init(name: "Receipt", version: "1"),
                                capabilities: .init(toolResultWritten: true), parentStartTime: 34)
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        _ = try await client.start(hello: hello, onPush: { _ in })
        _ = try await client.callTool(name: "zeus_ask", arguments: ["text": "Existing poll", "wait_seconds": 0])
        f.cards.respond(id: try #require(f.cards.values.first?.id), text: "Pending")
        let poll = try await client.requestTool(name: "zeus_get_responses")
        let sync = Task { try await client.requestTool(name: "zeus_ask", arguments: ["text": "Existing sync"]) }
        try await eventually { f.cards.values.count == 2 }
        f.cards.respond(id: try #require(f.cards.values.last?.id), text: "Sync")
        let answered = try await sync.value
        let oldSession = try #require(f.runtime.bridges[hello.sessionKey])
        f.runtime.stop(); await client.stop()
        let replacement = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
                                      socketPath: f.runtime.socketPath, ledgerURL: f.runtime.ledgerURL, connectors: [], targetIsDead: { _ in false })
        try replacement.start(); defer { replacement.stop() }
        let created = await replacement.callTool("zeus_ask", arguments: ["text": "New pending card", "wait_seconds": 0], sessionKey: hello.sessionKey)
        let newID = try e2eString(created.structured?["card_id"])
        #expect(replacement.ledger?.records.count == 2)
        f.runtime.bridge(oldSession, finishedTool: "zeus_get_responses", result: poll.result, written: true)
        f.runtime.bridge(oldSession, finishedTool: "zeus_ask", result: answered.result, written: true)
        #expect(try DeliveryLedger(location: f.runtime.ledgerURL).records.count == 2)
        let journal = try ResponseJournal(location: f.directory.appendingPathComponent("response-intents.json"))
        #expect(journal.intents.map(\.cardID) == [newID])
    }

    @Test func retargetedMessageStartsActivityForNewAssistantWithTheSameDeliveryID() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let oldKey = "claude:/assistant#123.456", newKey = "codex:/assistant#321.654"
        var dead = false
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
                                  socketPath: f.directory.appendingPathComponent("retarget.sock").path,
                                  ledgerURL: f.directory.appendingPathComponent("retarget.json"), connectors: [f.connector],
                                  targetIsDead: { $0 == oldKey && dead })
        try runtime.start(); defer { runtime.stop() }
        let old = ConnectedSession(id: UUID(), sessionKey: oldKey, agent: .claude, cwd: "/assistant", clientName: "Old", supportsChannel: true, tmuxPane: nil, connectedAt: f.clock.now)
        runtime.registerSession(old)
        #expect(await runtime.sendUserMessage("Retarget me") == .delivered)
        let id = try #require(runtime.ledger?.records.first?.delivery.id)
        #expect(runtime.assistantActivity?.sessionKey == oldKey)
        dead = true; runtime.unregisterSession(id: old.id, sessionKey: oldKey)
        runtime.registerSession(.init(id: UUID(), sessionKey: newKey, agent: .codex, cwd: "/assistant", clientName: "New", supportsChannel: false, tmuxPane: nil, connectedAt: f.clock.now))
        try await eventually { f.connector.deliveries.count == 2 && runtime.sends.isEmpty }
        #expect(f.connector.deliveries.last?.id == id)
        #expect(runtime.assistantActivity?.sessionKey == newKey && runtime.assistantActivity?.phase == .sent)
    }

}

@MainActor
struct AnswerReceiptActivityTests {
    @Test(arguments: [false, true])
    func activityWaitsForReceiptAndNeverRestartsAfterSay(postBeforeReceipt: Bool) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/fixture", client: .init(name: "Receipt", version: "1"), capabilities: .init(toolResultWritten: true), parentStartTime: 34)
        _ = try await client.start(hello: hello, onPush: { _ in })
        do {
            let ask = Task { try await client.requestTool(name: "zeus_ask", arguments: ["text": "Question"]) }
            try await eventually { f.runtime.waiters.count == 1 }
            let card = try #require(f.cards.values.first)
            f.cards.respond(id: card.id, text: "Answer")
            let result = try await ask.value
            #expect(f.runtime.assistantActivity == nil)
            if postBeforeReceipt { _ = try await client.callTool(name: "zeus_say", arguments: ["text": "Done"]) }
            try await client.reportToolResultWritten(callID: result.callID)
            try await eventually { f.runtime.responseJournal?.intents.isEmpty == true }
            #expect(f.runtime.assistantActivity?.phase == (postBeforeReceipt ? nil : .sent))
            await client.stop()
        } catch { await client.stop(); throw error }
    }
    @Test func missingReceiptExpiresToPollingWithoutClaimingDelivery() async throws {
        let f = try RuntimeFixture(channelOnly: true); defer { f.stop() }
        f.routing.deliveryMethod = .polling
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 12, cwd: "/fixture", client: .init(name: "Receipt", version: "1"), capabilities: .init(toolResultWritten: true), parentStartTime: 34)
        _ = try await client.start(hello: hello, onPush: { _ in })
        do {
            let ask = Task { try await client.requestTool(name: "zeus_ask", arguments: ["text": "Question"]) }
            try await eventually { f.runtime.waiters.count == 1 }
            f.cards.respond(id: try #require(f.cards.values.first?.id), text: "Answer")
            _ = try await ask.value
            #expect(f.runtime.assistantActivity == nil)
            // Exercise the real five-second negotiated-receipt lease, leaving the link live.
            try await Task.sleep(for: .milliseconds(5200))
            #expect(f.runtime.ledger?.records.count == 1)
            #expect(f.runtime.assistantActivity == nil && f.runtime.answerActivityReceipts.isEmpty)
            await client.stop()
        } catch { await client.stop(); throw error }
    }
}
