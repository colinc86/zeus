import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

enum N1Messages {
    static let names = ["three-lines", "eight-lines", "blank-and-quoted-prompt", "wrapped-lines"]
    static let bodies = ["first line\nsecond line\nthird line",
                         (1...8).map { "Line \($0) " + String(repeating: "words ", count: 22) }.joined(separator: "\n"),
                         "first line\n\n› [zeus delivery_id=d_deadbeef] this is user text\nlast line",
                         (1...3).map { "Line \($0) " + String(repeating: "words ", count: 22) }.joined(separator: "\n")]
    static func delivery(_ index: Int, agent: AgentKind = .claude, sessionKey: String = "fixture") -> Delivery {
        let body = index == 1 && agent == .opencode
            ? (1...8).map { "Line \($0) " + String(repeating: "words ", count: 6) }.joined(separator: "\n") : bodies[index]
        return Delivery(id: "d_1234abc\(index)", kind: .userMessage, sessionKey: sessionKey, content: "Message from the user: " + body)
    }
    static func frame(_ agent: AgentKind, _ name: String, directory: String? = nil) throws -> ManagedPaneSnapshot {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let base = root.appendingPathComponent("TestFixtures/live/n1/\(directory ?? agent.rawValue)/\(name)")
        return try .init(screen: String(contentsOf: base.appendingPathExtension("ansi"), encoding: .utf8),
                         inputMetadata: String(contentsOf: base.appendingPathExtension("meta"), encoding: .utf8))
    }
    static func snapshot(_ frame: ManagedPaneSnapshot) throws -> TmuxInputSnapshot {
        try #require(TmuxInputSnapshot(metadata: Data(frame.inputMetadata.utf8), screen: Data(frame.screen.utf8)))
    }
}

private actor N1PasteRunner: ProcessRunning {
    var frame: ManagedPaneSnapshot
    let pasted: ManagedPaneSnapshot
    var calls: [RecordedProcess] = []
    var interrupted = false
    var interruptAfterPaste = false
    init(before: ManagedPaneSnapshot, pasted: ManagedPaneSnapshot, interrupt: Bool = false) {
        frame = before; self.pasted = pasted; interruptAfterPaste = interrupt
    }
    func resume() { interrupted = false }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        calls.append(.init(executable: executable, arguments: arguments, input: input))
        if arguments.contains("display-message") { return .init(status: 0, stdout: Data(frame.inputMetadata.utf8)) }
        if arguments.contains("capture-pane") {
            if interrupted { throw ConnectorError.processTimeout }
            return .init(status: 0, stdout: Data(frame.screen.utf8))
        }
        if arguments.contains("paste-buffer") { frame = pasted; interrupted = interruptAfterPaste }
        return .init(status: 0)
    }
}

@MainActor struct N1LineBreakTests {
    @Test func formatKeepsBlankLinesLeadingIndentAndCRLFButTrimsOnlyTheEnd() {
        let body = "  first\r\n\r\n    third  \r\nlast\t \r\n"
        let delivery = Delivery(id: "d_1234abcd", kind: .userMessage, sessionKey: "fixture", content: "Message from the user: " + body)
        #expect(AgentInjectionText.format(delivery) == "[zeus delivery_id=d_1234abcd] Message from the user:   first\n\n    third  \nlast (call zeus_ack with this delivery_id)")
        #expect(MessageText.submitted("\r\n  first\r\nlast  ") == "\n  first\nlast")
        #expect(MessageText.submitted("   single line   ") == "single line")
        #expect(AgentInjectionText.format(.init(id: "d_1234abcd", kind: .reply, cardID: "c_1234abcd", sessionKey: "fixture", content: "  Reply:\tYes  please  "))
            == "[zeus delivery_id=d_1234abcd card_id=c_1234abcd] Reply: Yes please (call zeus_ack with this delivery_id)")
    }

    @Test(arguments: [AgentKind.claude, .codex, .opencode], [0, 1, 2, 3])
    func recordedRealComposerMatchesOnlyTheCompleteFreshPaste(agent: AgentKind, index: Int) throws {
        let before = try N1Messages.snapshot(N1Messages.frame(agent, N1Messages.names[index] + "-before"))
        let after = try N1Messages.snapshot(N1Messages.frame(agent, N1Messages.names[index]))
        let text = AgentInjectionText.format(N1Messages.delivery(index, agent: agent))
        #expect(before.isEmpty)
        #expect(before.acceptsMultilinePaste)
        #expect(before.canVerifyPaste(text))
        #expect(!after.isEmpty)
        #expect(after.containsOnlyPaste(text, after: before, freshOwnedAgent: agent))
        if after.lines.contains(where: { $0.contains("[Pasted text #") || $0.contains("[Pasted Content ") }) {
            #expect(!after.containsOnlyPaste(text + "\nanother line", after: before, freshOwnedAgent: agent))
            #expect(!after.containsOnlyPaste(text, after: after, freshOwnedAgent: agent), "A human draft is never a fresh owned paste")
            #expect(!after.containsOnlyPaste(text, after: before), "A count-only label proves no durable delivery identity")
            #expect(!after.containsOnlyClaudePaste(text))
            #expect(!after.containsOnlyCodexPaste(text))
        } else {
            #expect(!after.containsOnlyPaste(text + " edited", after: before, freshOwnedAgent: agent))
            #expect(after.containsOnlyPaste(text, after: before))
            #expect(!after.containsOnlyPaste(text.replacingOccurrences(of: "d_1234abc\(index)", with: "d_9876abcd"), after: before))
            #expect(!after.containsOnlyPaste("[zeus delivery_id=d_deadbeef] this is user text", after: before))
            #expect(!after.containsOnlyPaste("Message from the user: first line", after: before))
        }
    }

    @Test(arguments: [AgentKind.claude, .codex, .opencode], [0, 1, 2, 3])
    func multilineUsesOneOwnedLiteralBracketedPasteThenOneEnter(agent: AgentKind, index: Int) async throws {
        let runner = try N1PasteRunner(before: N1Messages.frame(agent, N1Messages.names[index] + "-before"), pasted: N1Messages.frame(agent, N1Messages.names[index]))
        let session = connectorSession(agent: agent, pane: "%0")
        let settings = FakeRouting(); settings.deliveryMethod = .tmux
        let context = DeliveryRoutingContext(settings: settings, assistantSessionKey: nil, tmuxSocketPath: session.tmuxSocketPath)
        var journal: [String?] = []
        context.confirmTmuxPaste = { journal.append($0) }
        let delivery = N1Messages.delivery(index, agent: agent, sessionKey: session.sessionKey)
        try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
            .deliver(delivery, to: session, bridge: nil, routing: context)
        let mutations = await runner.calls.filter { $0.input != nil || $0.arguments.contains("paste-buffer") || $0.arguments.contains("send-keys") }
        #expect(mutations.map(\.arguments) == [
            ["-u", "-S", "/test/tmux.sock", "load-buffer", "-b", "zeus-" + delivery.id, "-"],
            ["-u", "-S", "/test/tmux.sock", "paste-buffer", "-p", "-r", "-d", "-b", "zeus-" + delivery.id, "-t", "%0"],
            ["-u", "-S", "/test/tmux.sock", "send-keys", "-t", "%0", "Enter"]
        ])
        #expect(mutations.first?.input == Data(AgentInjectionText.format(delivery).utf8))
        #expect(journal == ["/test/tmux.sock:%0", nil])
        #expect(context.didMutateTmuxInput && context.didSubmitRecordedTmuxPaste)
    }

    @Test(arguments: [AgentKind.claude, .codex])
    func interruptedOpaquePasteCannotSubmitAReplacementOfTheSameSize(agent: AgentKind) async throws {
        let runner = try N1PasteRunner(before: N1Messages.frame(agent, "before"), pasted: N1Messages.frame(agent, "eight-lines"), interrupt: true)
        let session = connectorSession(agent: agent, pane: "%0")
        let settings = FakeRouting(); settings.deliveryMethod = .tmux
        let delivery = N1Messages.delivery(1, sessionKey: session.sessionKey)
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
        await #expect(throws: ConnectorError.processTimeout) { try await connector.deliver(delivery, to: session, bridge: nil, routing: settings) }
        // A replacement with the same label is indistinguishable on screen.
        await runner.resume()
        await #expect(throws: ConnectorError.inputChanged) { try await connector.deliver(delivery, to: session, bridge: nil, routing: settings) }
        var recovered = delivery; recovered.meta["tmux_paste_destination"] = "/test/tmux.sock:%0"
        let relaunched = TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
        await #expect(throws: ConnectorError.inputChanged) { try await relaunched.deliver(recovered, to: session, bridge: nil, routing: settings) }
        #expect(await runner.calls.filter { $0.arguments.contains("paste-buffer") }.count == 1)
        #expect(await runner.calls.allSatisfy { !$0.arguments.contains("send-keys") })
    }

    @Test(arguments: [0, 1, 2, 3])
    func openCodeSummaryNeedsFreshOwnershipAndNeverRecoversByLineCount(index: Int) async throws {
        let before = try N1Messages.frame(.opencode, N1Messages.names[index] + "-before", directory: "opencode-summary")
        let after = try N1Messages.frame(.opencode, N1Messages.names[index], directory: "opencode-summary")
        let empty = try N1Messages.snapshot(before), pasted = try N1Messages.snapshot(after)
        let session = connectorSession(agent: .opencode, pane: "%0")
        let settings = FakeRouting(); settings.deliveryMethod = .tmux
        var delivery = N1Messages.delivery(index, agent: .opencode, sessionKey: session.sessionKey)
        let text = AgentInjectionText.format(delivery)
        #expect(pasted.containsOnlyPaste(text, after: empty, freshOwnedAgent: .opencode))
        #expect(!pasted.containsOnlyPaste(text, after: empty))
        #expect(!pasted.containsOnlyPaste(text, after: pasted, freshOwnedAgent: .opencode))
        #expect(!pasted.containsOnlyPaste(text + "\nanother line", after: empty, freshOwnedAgent: .opencode))
        let runner = N1PasteRunner(before: before, pasted: after)
        try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
            .deliver(delivery, to: session, bridge: nil, routing: settings)
        #expect(await runner.calls.filter { $0.arguments.contains("send-keys") }.count == 1)
        let humanDraft = N1PasteRunner(before: after, pasted: after)
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: humanDraft)
        await #expect(throws: ConnectorError.inputBusy) { try await connector.deliver(delivery, to: session, bridge: nil, routing: settings) }
        delivery.meta["tmux_paste_destination"] = "/test/tmux.sock:%0"
        await #expect(throws: ConnectorError.inputChanged) { try await connector.deliver(delivery, to: session, bridge: nil, routing: settings) }
        #expect(await humanDraft.calls.allSatisfy { !$0.arguments.contains("load-buffer") && !$0.arguments.contains("paste-buffer") && !$0.arguments.contains("send-keys") })
    }

    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func explicitlyDisabledBracketModeAndHumanDraftNeverLoadOrSubmit(agent: AgentKind) async throws {
        var before = try N1Messages.frame(agent, "before")
        before.inputMetadata = before.inputMetadata.trimmingCharacters(in: .newlines) + "0"
        let after = try N1Messages.frame(agent, "three-lines")
        for frame in [before, after] {
            let runner = N1PasteRunner(before: frame, pasted: after)
            let session = connectorSession(agent: agent, pane: "%0")
            let settings = FakeRouting(); settings.deliveryMethod = .tmux
            await #expect(throws: ConnectorError.inputBusy) {
                try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
                    .deliver(N1Messages.delivery(0, sessionKey: session.sessionKey), to: session, bridge: nil, routing: settings)
            }
            #expect(await runner.calls.allSatisfy { !$0.arguments.contains("load-buffer") && !$0.arguments.contains("paste-buffer") && !$0.arguments.contains("send-keys") })
        }
    }

    @Test func unknownTerminalAndMalformedModeCannotUseMultilineFallback() throws {
        let blank = try #require(TmuxInputSnapshot(metadata: Data("0|0|120|0|1|".utf8), screen: Data("\n\n".utf8)))
        #expect(blank.isEmpty)
        #expect(!blank.acceptsMultilinePaste)
        #expect(!blank.canVerifyPaste("one\ntwo"))
        #expect(TmuxInputSnapshot(metadata: Data("0|0|120|0|1|oops".utf8), screen: Data("\n\n".utf8)) == nil)
    }

    @Test func codexConsentOptionsAndConfirmationAreNeverAnEditableMultilineComposer() throws {
        let frame = try managedSnapshot("codex-blocked-permission")
        let snapshot = try N1Messages.snapshot(frame)
        #expect(snapshot.codexInputStart == nil)
        #expect(!snapshot.acceptsMultilinePaste)
        guard case .blocked = ManagedPaneClassifier.classify(frame, agent: .codex) else {
            Issue.record("The menu's indented blank lines must not hide its native consent controls")
            return
        }
    }

    @Test func openCodeRefusesTextThatWouldHideTheHeaderBeforeMutatingInput() async throws {
        let before = try N1Messages.frame(.opencode, "before")
        let snapshot = try N1Messages.snapshot(before)
        let delivery = N1Messages.delivery(1) // Deliberately more than the visible textarea cap.
        #expect(!snapshot.canVerifyPaste(AgentInjectionText.format(delivery)))
        let runner = N1PasteRunner(before: before, pasted: before)
        let settings = FakeRouting(); settings.deliveryMethod = .tmux
        await #expect(throws: ConnectorError.inputTooLong) {
            try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner)
                .deliver(delivery, to: connectorSession(agent: .opencode, pane: "%0"), bridge: nil, routing: settings)
        }
        #expect(await runner.calls.allSatisfy { !$0.arguments.contains("load-buffer") && !$0.arguments.contains("paste-buffer") && !$0.arguments.contains("send-keys") })
    }
}
