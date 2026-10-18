import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private func openCodeRecoveryFrame(_ text: String) -> ManagedPaneSnapshot {
    var body: [String] = []
    for paragraph in text.components(separatedBy: "\n") {
        var remaining = paragraph[...]
        repeat {
            let line = String(remaining.prefix(112)); body.append(line)
            remaining = remaining.dropFirst(line.count)
        } while !remaining.isEmpty
    }
    var rows = Array(repeating: "", count: 40)
    let start = 34 - body.count
    rows[start] = "  ┃"
    for (i, line) in body.enumerated() { rows[start + 1 + i] = "  ┃  " + line }
    rows[35] = "  ┃  Build · fixture"
    rows[36] = "  ╹━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    rows[37] = "  ctrl+p commands"
    return .init(screen: rows.joined(separator: "\n"), inputMetadata: "\(5 + (body.last?.count ?? 0))|34|120|0|1|1")
}

private actor OpenCodeRecoveryRunner: ProcessRunning {
    var frame: ManagedPaneSnapshot
    var buffer = ""
    var enters = 0, pastes = 0
    init(text: String) { frame = openCodeRecoveryFrame(text) }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        if arguments.contains("display-message") { return .init(status: 0, stdout: Data(frame.inputMetadata.utf8)) }
        if arguments.contains("capture-pane") { return .init(status: 0, stdout: Data(frame.screen.utf8)) }
        if arguments.contains("load-buffer") { buffer = String(decoding: input ?? Data(), as: UTF8.self) }
        if arguments.contains("paste-buffer") { pastes += 1; frame = openCodeRecoveryFrame(buffer) }
        if arguments.contains("send-keys") { enters += 1; frame = openCodeRecoveryFrame("") }
        return .init(status: 0)
    }
}

@MainActor
struct OpenCodePasteRecoveryTests {
    @Test(arguments: [1, 5], ["exact", "edited", "hidden"])
    func persistedPasteRecoversWithFreshRuntimeAndUnblocksLaterDelivery(attempts: Int, state: String) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .tmux
        let session = connectorSession(agent: .opencode, pane: "%0", socket: "/test/tmux.sock")
        var delivery = Delivery(id: "d_recover", kind: .userMessage, sessionKey: session.sessionKey,
            content: String(repeating: "A bounded morning brief with useful context. ", count: 3) + "\nSecond line.",
            meta: ["tmux_paste_destination": "/test/tmux.sock:%0"])
        delivery.attempts = attempts
        if attempts == 5 { delivery.failedAt = f.clock.now }
        let text = AgentInjectionText.format(delivery)
        let runner = OpenCodeRecoveryRunner(text: state == "hidden" ? "[Pasted ~2 lines] " : text + (state == "edited" ? "x" : ""))
        func makeRuntime() -> ZeusRuntime {
            ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
                socketPath: f.directory.appendingPathComponent("recovery.sock").path,
                ledgerURL: f.directory.appendingPathComponent("recovery.json"),
                connectors: [TmuxConnector(executable: URL(fileURLWithPath: "/bin/cat"), runner: runner)], targetIsDead: { _ in false })
        }
        let first = makeRuntime(); try first.start()
        try first.ledger?.insert(.init(delivery: delivery))
        first.stop()
        let next = makeRuntime(); try next.start(); defer { next.stop() }
        next.registerSession(session)
        try await eventually { next.sends.isEmpty }
        #expect(await runner.enters == (state == "exact" ? 1 : 0))
        #expect(await runner.pastes == 0)
        #expect(next.ledger?.record(id: delivery.id)?.delivery.attempts == attempts)
        if state == "exact" {
            #expect(next.ledger?.record(id: delivery.id)?.delivery.meta["tmux_paste_destination"] == nil)
            #expect(next.ledger?.record(id: delivery.id)?.tmuxPasteRecoveredAt == f.clock.now)
            next.processDueDeliveries()
            #expect(await runner.enters == 1)
            let result = await next.sendUserMessage("Later message", deliveryID: "d_later")
            #expect(result == .delivered)
            #expect(await runner.enters == 2)
            #expect(await runner.pastes == 1)
        } else {
            #expect(next.ledger?.record(id: delivery.id)?.delivery.meta["tmux_paste_destination"] != nil)
            _ = await next.sendUserMessage("Later message", deliveryID: "d_later")
            #expect(await runner.enters == 0)
            #expect(await runner.pastes == 0)
            if state == "hidden" {
                #expect(next.ledger?.record(id: delivery.id)?.queueReason == TmuxPasteRecoveryError.hidden.localizedDescription)
                f.clock.advance(121); next.processDueDeliveries()
                #expect(next.deliveryIssue?.detail == TmuxPasteRecoveryError.hidden.localizedDescription)
            }
        }
    }

    @Test func recoveryRejectsTextBelowCaretAndHiddenLabels() throws {
        let text = "Exact text"
        var frame = openCodeRecoveryFrame(text)
        var lines = frame.screen.components(separatedBy: "\n")
        lines.insert("  ┃  additional human text", at: 35)
        frame = .init(screen: lines.joined(separator: "\n"), inputMetadata: frame.inputMetadata)
        let input = try #require(TmuxInputSnapshot(metadata: Data(frame.inputMetadata.utf8), screen: Data(frame.screen.utf8)))
        #expect(!input.containsOnlyOpenCodePaste(text))
        let hidden = openCodeRecoveryFrame("[Pasted ~2 lines] ")
        let hiddenInput = try #require(TmuxInputSnapshot(metadata: Data(hidden.inputMetadata.utf8), screen: Data(hidden.screen.utf8)))
        #expect(!hiddenInput.containsOnlyOpenCodePaste("[Pasted ~2 lines]"))
    }
}
