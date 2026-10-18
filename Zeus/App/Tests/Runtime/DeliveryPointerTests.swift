import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@Suite @MainActor struct DeliveryPointerTests {
    @Test func pointerFitsSmallPaneAndKeepsDurableBody() throws {
        let screen = Array(repeating: "", count: 18) + [String(repeating: "─", count: 80), "❯ ", String(repeating: "─", count: 80), "", "", ""]
        let input = try #require(TmuxInputSnapshot(metadata: Data("2|19|80|0|1|1".utf8), screen: Data(screen.joined(separator: "\n").utf8)))
        for kind: Delivery.Kind in [.reply, .userMessage, .learning, .reflection, .brief, .ruleTrigger] {
            var delivery = Delivery(id: "d_" + UUID().uuidString, kind: kind, sessionKey: "fixture", content: String(repeating: "Long line of private fixture text.\n", count: 300))
            let original = delivery.content
            #expect(!input.canVerifyPaste(AgentInjectionText.format(delivery)))
            delivery.meta["tmux_pointer"] = "true"
            #expect(input.canVerifyPaste(AgentInjectionText.format(delivery)))
            #expect(delivery.content == original)
            #expect(!AgentInjectionText.format(delivery).contains("private fixture"))
        }
    }

    @Test func interruptedPointerIsJournaledAndRecoveredOnceWithoutRepasting() async throws {
        let runner = PointerPasteRunner()
        let settings = FakeRouting(); settings.deliveryMethod = .tmux
        let session = connectorSession(agent: .claude, pane: "%0")
        let context = DeliveryRoutingContext(settings: settings, assistantSessionKey: session.sessionKey, tmuxSocketPath: session.tmuxSocketPath)
        var delivery = Delivery(id: "d_" + UUID().uuidString, kind: .reflection, sessionKey: session.sessionKey,
            content: String(repeating: "Full reflection body\n", count: 600))
        defer { context.confirmTmuxPaste = nil }
        context.confirmTmuxPaste = { destination in
            delivery.meta["tmux_paste_destination"] = destination
            if destination != nil { delivery.meta["tmux_pointer"] = context.usesTmuxPointer ? "true" : nil }
        }
        await #expect(throws: ConnectorError.processTimeout) {
            try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
                .deliver(delivery, to: session, bridge: nil, routing: context)
        }
        #expect(delivery.meta["tmux_pointer"] == "true")
        #expect(delivery.meta["tmux_paste_destination"] != nil)
        #expect(await runner.loads == 1)
        #expect(await runner.enters == 0)
        await runner.resume()
        context.onlySubmitRecordedTmuxPaste = true
        try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
            .deliver(delivery, to: session, bridge: nil, routing: context)
        #expect(await runner.loads == 1)
        #expect(await runner.enters == 1)
        #expect(delivery.meta["tmux_paste_destination"] == nil)
        #expect(delivery.content.hasPrefix("Full reflection body"))
    }

    @Test func exactFetchIsScopedDoesNotAcknowledgeLearningAndRejectsDiscard() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let key = "claude:/fixture#123.1"
        let text = "Keep exact whitespace.\n\nUnicode: café 🐈\n"
        let delivery = Delivery(id: "d_pointer", kind: .reflection, sessionKey: key, content: text, createdAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        let result = await f.runtime.callTool("zeus_get_learnings", arguments: ["id": "d_pointer"], sessionKey: key)
        #expect(!result.isError)
        #expect(result.structured?["delivery"]?["content"] == .string(text))
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == nil)
        let foreign = await f.runtime.callTool("zeus_get_learnings", arguments: ["id": "d_pointer"], sessionKey: "other")
        #expect(foreign.isError)
        try f.runtime.ledger?.updateRecord(id: delivery.id) { $0.discardedAt = f.clock.now }
        let erased = await f.runtime.callTool("zeus_get_learnings", arguments: ["id": "d_pointer"], sessionKey: key)
        #expect(erased.isError)
    }

    @Test func userPointerFetchReturnsFullEnvelopeBodyAndConsumptionAcknowledges() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let key = "claude:/fixture#123.1", text = "You said:\n\nExact user message\n"
        let delivery = Delivery(id: "d_user_pointer", kind: .userMessage, sessionKey: key, content: text, createdAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery, userText: "Exact user message"))
        let result = await f.runtime.callTool("zeus_get_responses", arguments: ["id": .string(delivery.id)], sessionKey: key)
        #expect(!result.isError)
        if case .array(let items) = result.structured?["items"] { #expect(items.first?["text"] == .string(text)) }
        else { Issue.record("Missing fetched message") }
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt != nil)
    }

    @Test func submittedPointerRecordsFullBodyWithoutFabricatingAck() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        var delivery = Delivery(id: "d_pointer_receipt", kind: .reflection, sessionKey: "claude:/fixture#123.1", content: "Full body\nnot the pointer", createdAt: f.clock.now)
        delivery.meta["tmux_pointer"] = "true"
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        f.runtime.recordReflectionReceipt(id: delivery.id)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        try f.runtime.ledger?.updateRecord(id: delivery.id) { $0.transportDeliveredAt = f.clock.now }
        f.runtime.recordReflectionReceipt(id: delivery.id)
        let rows = try f.journal.items(matching: .init())
        #expect(rows.count == 1 && rows.first?.payload.value.text == delivery.content)
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.ackedAt == nil)
        _ = try f.runtime.acknowledge(ids: [delivery.id], sessionKey: delivery.sessionKey)
        #expect(try f.journal.items(matching: .init()).count == 1)
    }

    @Test func startupRetriesOnlySizeHoldsAndExpiresOldRequestsHonestly() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let key = "claude:/fixture#123.1"
        for (id, kind, age, reason) in [("size", Delivery.Kind.userMessage, 0.0, ConnectorError.inputTooLong.localizedDescription),
                                      ("other", .userMessage, 0, "Other failure"),
                                      ("old_reflection", .reflection, 3 * 86400, "Waiting"),
                                      ("old_brief", .brief, 86400, "Waiting")] {
            var delivery = Delivery(id: id, kind: kind, sessionKey: key, content: "Saved body", createdAt: f.clock.now.addingTimeInterval(-age))
            delivery.attempts = 5; delivery.failedAt = f.clock.now
            try f.runtime.ledger?.insert(.init(delivery: delivery, queueReason: reason))
        }
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.record(id: "size")?.delivery.failedAt == nil)
        #expect(f.runtime.ledger?.record(id: "size")?.delivery.attempts == 0)
        #expect(f.runtime.ledger?.record(id: "other")?.delivery.attempts == 5)
        for id in ["old_reflection", "old_brief"] {
            let record = try #require(f.runtime.ledger?.record(id: id))
            #expect(record.discardedAt != nil && record.delivery.ackedAt == nil && record.transportDeliveredAt == nil)
            #expect(record.queueReason == "Not sent: this request is out of date.")
            #expect(f.cards.learningNotices.contains { $0.id == "n_" + id && $0.summary.hasPrefix("Not sent:") })
            #expect(try f.runtime.acknowledge(ids: [id], sessionKey: key).isEmpty)
        }
        #expect(try !f.journal.items(matching: .init()).contains { $0.kind == .sentToAssistant })
    }
}

/// A bounded 80×24 Claude composer; only owned fixture text is ever rendered.
private actor PointerPasteRunner: ProcessRunning {
    private var text = ""
    private var buffer = ""
    private var interrupted = false
    private var shouldInterrupt = true
    var loads = 0
    var enters = 0
    func resume() { interrupted = false; shouldInterrupt = false }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        if interrupted { throw ConnectorError.processTimeout }
        var rows: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty && line.count + 1 + word.count > 76 { rows.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + word
        }
        rows.append(line)
        let start = 20 - rows.count
        let screen = Array(repeating: "", count: start - 1) + [String(repeating: "─", count: 80)]
            + rows.enumerated().map { ($0.offset == 0 ? "❯ " : "  ") + $0.element }
            + [String(repeating: "─", count: 80), "", "", ""]
        if arguments.contains("display-message") { return .init(status: 0, stdout: Data("\(2 + line.count)|19|80|0|1|1".utf8)) }
        if arguments.contains("capture-pane") { return .init(status: 0, stdout: Data(screen.joined(separator: "\n").utf8)) }
        if arguments.contains("load-buffer") { loads += 1; buffer = String(decoding: input ?? Data(), as: UTF8.self) }
        if arguments.contains("paste-buffer") { text = buffer; interrupted = shouldInterrupt }
        if arguments.contains("send-keys") { enters += 1; text = "" }
        return .init(status: 0)
    }
}
