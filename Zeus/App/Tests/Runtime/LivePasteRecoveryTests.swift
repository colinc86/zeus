import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

func liveUnsubmittedClaudeSnapshot() throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let screen = try String(contentsOf: root.appendingPathComponent("TestFixtures/live/m5b-claude-unsubmitted-pane.ansi"), encoding: .utf8)
    return .init(screen: screen, inputMetadata: "70|35|120|0|0")
}

actor LivePasteRunner: ProcessRunning {
    var snapshot: ManagedPaneSnapshot
    var failAfterPaste = false
    var calls: [[String]] = []
    init(snapshot: ManagedPaneSnapshot) { self.snapshot = snapshot }
    func set(_ snapshot: ManagedPaneSnapshot) { self.snapshot = snapshot }
    func failNextPasteVerification() { failAfterPaste = true }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        calls.append(arguments)
        if arguments.contains("capture-pane") {
            if failAfterPaste { throw ConnectorError.processTimeout }
            return .init(status: 0, stdout: Data(snapshot.screen.utf8))
        }
        if arguments.contains("display-message") { return .init(status: 0, stdout: Data(snapshot.inputMetadata.utf8)) }
        return .init(status: 0)
    }
}

actor InterruptedPasteRunner: ProcessRunning {
    let empty: ManagedPaneSnapshot
    let pasted: ManagedPaneSnapshot
    var snapshot: ManagedPaneSnapshot
    var interrupt = false
    var calls: [[String]] = []
    init(empty: ManagedPaneSnapshot, pasted: ManagedPaneSnapshot) { self.empty = empty; self.pasted = pasted; snapshot = empty }
    func edit() { snapshot = .init(screen: pasted.screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id)x"), inputMetadata: "71|35|120|0|0") }
    func resumeVerification() { interrupt = false }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        calls.append(arguments)
        if arguments.contains("display-message") { return .init(status: 0, stdout: Data(snapshot.inputMetadata.utf8)) }
        if arguments.contains("capture-pane") {
            if interrupt { throw ConnectorError.processTimeout }
            return .init(status: 0, stdout: Data(snapshot.screen.utf8))
        }
        if arguments.contains("paste-buffer") { snapshot = pasted; interrupt = true }
        if arguments.contains("send-keys") { snapshot = empty }
        return .init(status: 0)
    }
}

@MainActor
struct LivePasteRecoveryTests {
    let text = "[zeus delivery_id=d_fc1f6b5d] Message from the user: Live test from your PM: reply through Zeus with the word PINEAPPLE and today's weekday. (call zeus_ack with this delivery_id)"
    @Test(arguments: ["0", "1"])
    func liveTwoLineInputMatchesWithChangingCustomStatusline(cursor: String) throws {
        let live = try liveUnsubmittedClaudeSnapshot()
        let value = try #require(TmuxInputSnapshot(metadata: Data("70|35|120|0|\(cursor)".utf8), screen: Data(live.screen.utf8)))
        #expect(value.containsOnlyClaudePaste(text))
        #expect(!value.isEmpty)
        #expect(!value.containsOnlyClaudePaste(text + " edited"))
        let edited = try #require(TmuxInputSnapshot(metadata: Data("71|35|120|0|\(cursor)".utf8), screen: Data(live.screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id)x").utf8)))
        #expect(!edited.containsOnlyClaudePaste(text))
        let unicodeEdit = try #require(TmuxInputSnapshot(metadata: Data(live.inputMetadata.utf8), screen: Data(live.screen.replacingOccurrences(of: "PINEAPPLE and", with: "PINEAPPLE\u{00a0}and").utf8)))
        #expect(!unicodeEdit.containsOnlyClaudePaste(text), "Normalize the prompt's NBSP only, never a human edit inside input")
        // Control: the input stays identical while the independently rendered clock changes.
        let ticking = try #require(TmuxInputSnapshot(metadata: Data(live.inputMetadata.utf8), screen: Data(live.screen.replacingOccurrences(of: "[09:40]", with: "[09:41]").utf8)))
        #expect(ticking.containsOnlyPaste(text, after: value))
    }
    @Test func durableOwnedPasteIsSubmittedWithoutRepastingOrAcceptingAnEditedDraft() async throws {
        let live = try liveUnsubmittedClaudeSnapshot()
        let runner = LivePasteRunner(snapshot: live)
        let routing = FakeRouting(); routing.deliveryMethod = .tmux; routing.tmuxTarget = nil
        let session = connectorSession(agent: .claude, pane: "%0", socket: "/test/tmux.sock")
        let delivery = Delivery(id: "d_fc1f6b5d", kind: .userMessage, sessionKey: session.sessionKey,
            content: "Message from the user: Live test from your PM: reply through Zeus with the word PINEAPPLE and today's weekday.",
            meta: ["tmux_paste_destination": "/test/tmux.sock:%0"])
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/bin/cat"), runner: runner)
        try await connector.deliver(delivery, to: session, bridge: nil, routing: routing)
        #expect(await runner.calls.filter { $0.contains("send-keys") }.count == 1)
        #expect(await runner.calls.allSatisfy { !$0.contains("paste-buffer") })
        await runner.set(.init(screen: live.screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id)x"), inputMetadata: "71|35|120|0|0"))
        await #expect(throws: ConnectorError.inputChanged) { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        #expect(await runner.calls.filter { $0.contains("send-keys") }.count == 1)
    }
    @Test(arguments: [false, true], [1, 5])
    func interruptedPasteCountsAndRecoversAcrossRuntimeRelaunch(humanEdited: Bool, attempts: Int) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let live = try liveUnsubmittedClaudeSnapshot()
        var rows = live.screen.components(separatedBy: "\n")
        rows[34] = "❯ "; rows.remove(at: 35)
        let empty = ManagedPaneSnapshot(screen: rows.joined(separator: "\n"), inputMetadata: "2|34|120|0|0")
        let runner = InterruptedPasteRunner(empty: empty, pasted: live)
        f.routing.deliveryMethod = .tmux
        let session = ConnectedSession(id: UUID(), sessionKey: "claude:/assistant#1234.5678", agent: .claude, cwd: "/assistant", clientName: nil, supportsChannel: false, tmuxPane: "%0", connectedAt: f.clock.now, tmuxSocketPath: "/test/tmux.sock")
        func makeRuntime() -> ZeusRuntime {
            ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
                socketPath: f.directory.appendingPathComponent("paste.sock").path, ledgerURL: f.directory.appendingPathComponent("paste.json"),
                connectors: [TmuxConnector(executable: URL(fileURLWithPath: "/bin/cat"), runner: runner)], targetIsDead: { _ in false })
        }
        let first = makeRuntime(); try first.start(); first.registerSession(session)
        let result = await first.sendUserMessage("Live test from your PM: reply through Zeus with the word PINEAPPLE and today's weekday.", deliveryID: "d_fc1f6b5d")
        if case .queued = result {} else { Issue.record("The injected post-paste timeout should queue") }
        #expect(first.ledger?.record(id: "d_fc1f6b5d")?.delivery.attempts == 1)
        #expect(first.ledger?.record(id: "d_fc1f6b5d")?.delivery.meta["tmux_paste_destination"] != nil)
        try first.ledger?.update(id: "d_fc1f6b5d") {
            $0.attempts = attempts
            if attempts == 5 { $0.failedAt = f.clock.now }
        }
        first.stop()
        // Hold the injected I/O failure until shutdown; immediate owned-paste
        // recovery must not consume the relaunch fixture in the first runtime.
        await runner.resumeVerification()
        if humanEdited { await runner.edit() }
        let next = makeRuntime(); try next.start(); defer { next.stop() }; next.registerSession(session)
        // Connect bypasses backoff, but must recover this ID instead of pasting again.
        try await eventually { next.sends.isEmpty }
        #expect(await runner.calls.filter { $0.contains("paste-buffer") }.count == 1)
        #expect(await runner.calls.filter { $0.contains("send-keys") }.count == (humanEdited ? 0 : 1))
        #expect(next.ledger?.record(id: "d_fc1f6b5d")?.delivery.attempts == attempts)
        #expect((next.ledger?.record(id: "d_fc1f6b5d")?.transportDeliveredAt != nil) == !humanEdited, "\(String(describing: next.ledger?.record(id: "d_fc1f6b5d")))")
        if !humanEdited {
            #expect(next.ledger?.record(id: "d_fc1f6b5d")?.delivery.failedAt == nil)
            #expect(next.ledger?.record(id: "d_fc1f6b5d")?.tmuxPasteRecoveredAt == f.clock.now)
            next.registerSession(session)
            next.processDueDeliveries()
            f.clock.advance(179)
            next.processDueDeliveries()
            await Task.yield()
            #expect(await runner.calls.filter { $0.contains("send-keys") }.count == 1)
            #expect(await runner.calls.filter { $0.contains("paste-buffer") }.count == 1)
            if attempts == 5 {
                f.clock.advance(1)
                next.processDueDeliveries()
                #expect(next.ledger?.record(id: "d_fc1f6b5d")?.delivery.failedAt != nil)
            }
        } else {
            #expect(next.ledger?.record(id: "d_fc1f6b5d")?.delivery.meta["tmux_paste_destination"] != nil)
            #expect(next.ledger?.record(id: "d_fc1f6b5d")?.queueReason == "Finishing Zeus's saved message in Terminal.")
        }
    }

    @Test(arguments: ["empty", "edited", "other-pane"])
    func recoveryOnlyNeverRepastesMissingEditedOrMovedInput(state: String) async throws {
        let live = try liveUnsubmittedClaudeSnapshot()
        var rows = live.screen.components(separatedBy: "\n")
        rows[34] = "❯ "; rows.remove(at: 35)
        let frame = state == "empty"
            ? ManagedPaneSnapshot(screen: rows.joined(separator: "\n"), inputMetadata: "2|34|120|0|0")
            : state == "edited"
                ? ManagedPaneSnapshot(screen: live.screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id)x"), inputMetadata: "71|35|120|0|0")
                : live
        let runner = LivePasteRunner(snapshot: frame)
        let settings = FakeRouting(); settings.deliveryMethod = .tmux
        let context = DeliveryRoutingContext(settings: settings, assistantSessionKey: nil, tmuxSocketPath: "/test/tmux.sock")
        context.onlySubmitRecordedTmuxPaste = true
        var retired = false
        context.confirmTmuxPaste = { retired = $0 == nil }
        let session = connectorSession(agent: .claude, pane: "%0", socket: "/test/tmux.sock")
        let delivery = Delivery(id: "d_fc1f6b5d", kind: .userMessage, sessionKey: session.sessionKey,
            content: "Message from the user: Live test from your PM: reply through Zeus with the word PINEAPPLE and today's weekday.",
            meta: ["tmux_paste_destination": state == "other-pane" ? "/test/tmux.sock:%1" : "/test/tmux.sock:%0"])
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/bin/cat"), runner: runner)
        do {
            try await connector.deliver(delivery, to: session, bridge: nil, routing: context)
            Issue.record("Recovery must refuse missing, edited or relocated input")
        } catch { }
        #expect(retired == (state == "empty"))
        #expect(!context.didSubmitRecordedTmuxPaste)
        #expect(await runner.calls.allSatisfy { !$0.contains("paste-buffer") && !$0.contains("load-buffer") && !$0.contains("send-keys") })
    }

}
