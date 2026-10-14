import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

func promptFixture(_ name: String) throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return .init(screen: try String(contentsOf: root.appendingPathComponent("TestFixtures/live/" + name + ".ansi"), encoding: .utf8),
                 inputMetadata: "0|0|120|0|0")
}

@MainActor
struct ManagedPromptAnswerTests {
    @Test func humanFourOptionClaudeCaptureHasTheQuestionAndExactChoices() throws {
        let prompt = try #require(ManagedPromptParser.parse(try promptFixture("claude-bash-approval-4-options"), agent: .claude))
        #expect(prompt.kind == .command && prompt.title == "Bash command")
        #expect(prompt.question == "Do you want to proceed?")
        #expect(prompt.options.count == 4)
        #expect(prompt.options.map(\.id) == ["1", "2", "3", "4"])
        #expect(prompt.options[0].label == "Yes" && prompt.options[3].label == "No")
        #expect(prompt.options[1].label.contains("Yes, and allow access to /Applications"))
        #expect(prompt.options[2].label == "Yes, and switch to auto mode · auto mode handles these prompts for you")
        #expect(prompt.options[3].key == .digit(4))
        #expect(prompt.detail.hasPrefix("which spark things things3 things-cli"))
        #expect(!prompt.detail.contains("Tip:") && !prompt.detail.contains("╌") && !prompt.detail.contains("│") && !prompt.detail.contains("Tab to amend"))
    }
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func realPermissionFixturesExposeOnlyTheirNativeChoices(agent: AgentKind) throws {
        let prompt = try #require(ManagedPromptParser.parse(try promptFixture("p1-\(agent.rawValue)-permission"), agent: agent))
        #expect(prompt.kind == .command)
        #expect(prompt.detail == "printf P1_PROCEEDED > p1-approval.txt")
        switch agent {
        case .claude:
            #expect(prompt.options.map(\.label) == ["Yes", "No"])
            #expect(prompt.options.map(\.key) == [.digit(1), .digit(2)])
        case .codex:
            #expect(prompt.options.map(\.id) == ["y", "p", "Escape"])
            #expect(prompt.options.map(\.key) == [.shortcut(.yes), .shortcut(.always), .shortcut(.cancel)])
        case .opencode:
            #expect(prompt.options.map(\.label) == ["Allow once", "Allow always", "Reject"])
            #expect(prompt.options.map(\.key) == [.horizontal(0), .horizontal(1), .horizontal(2)])
            #expect(prompt.highlightedOption == 0)
        case .other: Issue.record("Unsupported agent")
        }
    }
    @Test func fingerprintIgnoresHistoryColorAndHighlightButIncludesDetailsChoicesAndLifetime() throws {
        let original = try promptFixture("p1-claude-permission")
        let parsed = try #require(ManagedPromptParser.parse(original, agent: .claude, scope: "lifetime1"))
        var changed = original
        changed.screen = "Different history\n" + original.plainLines.joined(separator: "\n")
            .replacingOccurrences(of: "❯ 1. Yes", with: "1. Yes").replacingOccurrences(of: "2. No", with: "❯ 2. No")
        #expect(ManagedPromptParser.parse(changed, agent: .claude, scope: "lifetime1")?.fingerprint == parsed.fingerprint)
        changed.screen = original.screen.replacingOccurrences(of: "P1_PROCEEDED", with: "DIFFERENT_COMMAND")
        #expect(ManagedPromptParser.parse(changed, agent: .claude, scope: "lifetime1")?.fingerprint != parsed.fingerprint)
        changed.screen = original.plainLines.joined(separator: "\n").replacingOccurrences(of: "2. No", with: "2. Never")
        #expect(ManagedPromptParser.parse(changed, agent: .claude, scope: "lifetime1")?.fingerprint != parsed.fingerprint)
        #expect(ManagedPromptParser.parse(original, agent: .claude, scope: "lifetime2")?.fingerprint != parsed.fingerprint)
    }
    @Test func unknownOrAmbiguousDialogKeepsCleanTerminalFallbackAndNeverAssumesDefault() throws {
        var snapshot = try promptFixture("p1-opencode-permission")
        snapshot.screen = snapshot.plainLines.joined(separator: "\n")
        let fallback = try #require(ManagedPromptParser.parse(snapshot, agent: .opencode))
        #expect(fallback.options.isEmpty)
        #expect(!fallback.detail.contains("┃") && !fallback.detail.contains("enter confirm"))
        snapshot = try promptFixture("p1-codex-permission")
        snapshot.screen = snapshot.screen.replacingOccurrences(of: "(y)", with: "(unknown)")
        #expect(ManagedPromptParser.parse(snapshot, agent: .codex)?.options.isEmpty == true)
    }
    @Test(arguments: [1, 2, 3])
    func codexApprovalCursorOnNumberedSelectionIsNotAComposer(selected: Int) throws {
        var snapshot = try promptFixture("p1-codex-permission")
        var lines = snapshot.plainLines
        let old = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("› 1.") })
        lines[old] = lines[old].replacingOccurrences(of: "› ", with: "  ")
        let row = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(selected).") })
        lines[row] = "› " + lines[row].trimmingCharacters(in: .whitespaces)
        snapshot.screen = lines.joined(separator: "\n")
        snapshot.inputMetadata = "2|\(row)|120|0|0"
        #expect(ManagedPromptParser.parse(snapshot, agent: .codex)?.options.count == 3)
        guard case .blocked = ManagedPaneClassifier.classify(snapshot, agent: .codex) else { Issue.record("Approval is not an idle composer"); return }
    }
    @Test func editKindAndCodexContextArePartOfThePromptIdentity() throws {
        var edit = try promptFixture("p1-claude-permission")
        edit.screen = edit.screen.replacingOccurrences(of: "Bash command", with: "Edit file")
        #expect(ManagedPromptParser.parse(edit, agent: .claude)?.kind == .edit)
        var codex = try promptFixture("p1-codex-permission")
        let original = try #require(ManagedPromptParser.parse(codex, agent: .codex))
        codex.screen = codex.screen.replacingOccurrences(of: "local", with: "other-environment")
        #expect(ManagedPromptParser.parse(codex, agent: .codex)?.fingerprint != original.fingerprint)
        codex = try promptFixture("p1-codex-permission")
        codex.screen = codex.screen.replacingOccurrences(of: "  $", with: "    $")
        #expect(ManagedPromptParser.parse(codex, agent: .codex)?.fingerprint != original.fingerprint,
            "Visible command whitespace changes invalidate a captured authorization")
    }
    @Test func changedFingerprintChangedOptionAndFreeTextSendNothing() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let frame = try promptFixture("p1-claude-permission")
        await f.managed.host.setSnapshot(frame)
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        let prompt = try #require(f.runtime.managedPrompt)
        #expect(await f.runtime.answerManagedPrompt(fingerprint: "stale", optionID: "1") == .changed)
        #expect(await f.runtime.answerManagedPrompt(fingerprint: prompt.fingerprint, optionID: "1\nEnter") == .changed)
        let card = try #require(f.cards.values.first)
        f.cards.respond(id: card.id, option: card.options[0].id, text: "amend this command")
        #expect(await f.managed.host.promptAnswers.isEmpty)
        #expect(f.runtime.ledger?.records.isEmpty == true && f.cards.card(id: card.id)?.response == nil)
        await f.managed.host.setSnapshot(.init(screen: frame.screen.replacingOccurrences(of: "P1_PROCEEDED", with: "CHANGED"), inputMetadata: frame.inputMetadata))
        #expect(await f.runtime.answerManagedPrompt(fingerprint: prompt.fingerprint, optionID: "1") == .changed)
        #expect(await f.managed.host.promptAnswers.isEmpty)
        #expect(ManagedPromptAnswerResult.changed.message == "This question changed. Open Terminal to answer it.")
    }
    @Test func oneExplicitChoiceResolvesCardAndQueuedMessageWaitsUntilConfirmedIdle() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(try promptFixture("p1-claude-permission"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        let prompt = try #require(f.runtime.managedPrompt)
        let card = try #require(f.cards.values.first)
        #expect(card.input == nil && card.options.last?.id == "open-terminal")
        _ = await f.runtime.sendUserMessage("Wait behind approval", deliveryID: "d_prompt_wait")
        #expect(f.tmux.deliveries.isEmpty && f.runtime.ledger?.records.first?.delivery.attempts == 0)
        #expect(await f.managed.host.promptAnswers.isEmpty, "Sampling and timers never choose an option")
        #expect(await f.runtime.answerManagedPrompt(fingerprint: prompt.fingerprint, optionID: "1") == .answered(optionID: "1", label: "Yes"))
        #expect(f.cards.card(id: card.id)?.status == .answered)
        #expect(f.cards.card(id: card.id)?.body.hasSuffix("You chose Yes.") == true)
        #expect(f.cards.card(id: card.id)?.response == nil && f.runtime.ledger?.records.count == 1)
        #expect(await f.runtime.answerManagedPrompt(fingerprint: prompt.fingerprint, optionID: "1") == .changed)
        #expect(await f.managed.host.promptAnswers == ["1"])
        await f.managed.host.setSnapshot(.init(screen: "", inputMetadata: "0|0|120|0|0"))
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.cards.values.count == 1 && f.cards.card(id: card.id)?.status == .answered,
            "A repaint after the confirmed answer must not resurrect the old question")
        await f.managed.host.setSnapshot(try managedSnapshot("claude-idle"))
        f.managed.controller.refresh(); try await f.managed.settle()
        try await eventually { f.tmux.deliveries.count == 1 }
        #expect(f.status.state == nil, "The managed alert clears after the answered card releases its ID")
    }
    @Test func shutdownOrReplacementInvalidatesChoiceDuringRecaptureAndDoubleClickCannotSendTwice() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle(); f.clock.advance(10, wake: false)
        await f.host.setSnapshot(try promptFixture("p1-claude-permission"))
        for _ in 0..<2 { f.controller.refresh(); try await f.settle() }
        let prompt = try #require(f.controller.managedPrompt)
        await f.host.holdAnswer()
        let pending = Task { await f.controller.answerManagedPrompt(fingerprint: prompt.fingerprint, optionID: "1") }
        let end = ContinuousClock.now + .seconds(3)
        while await !f.host.awaitingPromptAnswer, ContinuousClock.now < end { await Task.yield() }
        try #require(await f.host.awaitingPromptAnswer)
        #expect(await f.controller.answerManagedPrompt(fingerprint: prompt.fingerprint, optionID: "1") == .changed)
        f.controller.shutdown()
        await f.host.releaseAnswer()
        #expect(await pending.value == .changed)
        #expect(await f.host.promptAnswers.isEmpty)
    }
}
