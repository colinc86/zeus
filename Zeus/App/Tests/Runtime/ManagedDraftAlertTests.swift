import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct ManagedDraftAlertTests {
    func draft() throws -> ManagedPaneSnapshot {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try .init(screen: String(contentsOf: root.appendingPathComponent("TestFixtures/live/p2-claude-human-draft.ansi"), encoding: .utf8),
            inputMetadata: String(contentsOf: root.appendingPathComponent("TestFixtures/live/p2-claude-human-draft.meta"), encoding: .utf8))
    }
    func sample(_ f: ManagedDeliveryFixture, _ frame: ManagedPaneSnapshot) async throws {
        await f.managed.host.setSnapshot(frame)
        f.managed.controller.refresh(); try await f.managed.settle()
        f.runtime.processDueDeliveries()
    }
    func ready(_ f: ManagedDeliveryFixture) async throws {
        try await f.start(); try await f.idle(); try await sample(f, draft())
    }
    func notice(_ f: ManagedDeliveryFixture) throws -> Card {
        try #require(f.cards.values.first { $0.id.hasPrefix(ZeusRuntime.managedDraftPrefix) })
    }
    func wait20(_ f: ManagedDeliveryFixture) async throws {
        f.managed.clock.advance(20, wake: false); try await sample(f, draft())
    }

    @Test func realDraftWaitsTwentySecondsAndAddsOnlyOneActionableCard() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await ready(f)
        #expect(await f.runtime.sendUserMessage("Queued first", deliveryID: "d_p2_one") != .delivered)
        #expect(f.runtime.ledger?.record(id: "d_p2_one")?.delivery.attempts == 0)
        #expect(f.runtime.managedDraftDeadline == f.managed.clock.now.addingTimeInterval(20))
        f.managed.clock.advance(19, wake: false); try await sample(f, draft())
        #expect(f.cards.values.isEmpty && f.runtime.managedDraftStatusDetail == "Waiting on unsent text in Terminal")
        f.managed.clock.advance(1, wake: false); try await sample(f, draft())
        let card = try notice(f)
        #expect(card.title == "Your assistant has unsent text in Terminal" && card.priority == .high && card.mood == .alert)
        #expect(card.options.map(\.id) == ["open-terminal", "cancel-draft-queue"] && card.options.map(\.style) == [.primary, .secondary])
        #expect(card.input == nil && card.sessionKey == f.runtime.managedController.sessionKey)
        let preview = card.body.components(separatedBy: "\n")[0]
        #expect(preview.count <= 80 && preview.hasPrefix("Hold this genuine draft"))
        #expect(card.body.contains("holding 1 message") && f.runtime.managedDraftStatusDetail == "Waiting on unsent text in Terminal")
        #expect(f.status.state == .alert && f.tmux.deliveries.isEmpty)
        _ = await f.runtime.sendUserMessage("Queued second", deliveryID: "d_p2_two")
        for _ in 0..<3 { f.managed.clock.advance(3, wake: false); try await sample(f, draft()) }
        #expect(f.cards.values.count == 1 && f.cards.card(id: card.id)?.body.contains("holding 2 messages") == true)
        f.cards.respond(id: card.id, option: "open-terminal"); try await f.managed.settle()
        #expect(f.managed.terminal.files.count == 1 && f.cards.card(id: card.id)?.status == .open)
        #expect(f.runtime.responseJournal?.intents.isEmpty == true && f.runtime.ledger?.records.count == 2)
        #expect(await f.managed.host.promptAnswers.isEmpty, "Opening Terminal never submits the human draft")
    }

    @Test func clearingTheDraftResolvesTheCardAndPreservesMessageIDs() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await ready(f)
        _ = await f.runtime.sendUserMessage("Saved", deliveryID: "d_p2_clear")
        try await wait20(f); let card = try notice(f)
        try await sample(f, managedSnapshot("claude-idle"))
        try await eventually { f.tmux.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.tmux.deliveries[0].id == "d_p2_clear")
        #expect(f.cards.card(id: card.id)?.status == .answered && f.cards.card(id: card.id)?.options.isEmpty == true)
        #expect(f.runtime.managedDraftStatusDetail == nil && f.status.state == nil)
        try await sample(f, draft())
        _ = await f.runtime.sendUserMessage("New episode", deliveryID: "d_p2_new")
        try await wait20(f)
        #expect(f.cards.values.count == 2 && f.runtime.managedDraftAlertCardID != card.id)
    }

    @Test func oneMessageCancelsDurablyWithoutTouchingOtherSessionsOrTerminal() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await ready(f)
        _ = await f.runtime.sendUserMessage("Cancel me", deliveryID: "d_p2_cancel")
        try f.runtime.ledger?.insert(.init(delivery: .init(id: "d_other", kind: .userMessage, sessionKey: "codex:/Other#99.1", content: "Other")))
        try await wait20(f); let card = try notice(f)
        f.cards.respond(id: card.id, option: "cancel-draft-queue")
        #expect(f.runtime.ledger?.record(id: "d_p2_cancel")?.discardedAt != nil)
        #expect(f.runtime.ledger?.record(id: "d_p2_cancel")?.delivery.ackedAt == nil)
        #expect(f.runtime.ledger?.record(id: "d_other")?.discardedAt == nil)
        #expect(f.cards.card(id: card.id)?.status == .answered && f.runtime.managedDraftCancellation == nil)
        let answers = await f.managed.host.promptAnswers
        #expect(f.tmux.deliveries.isEmpty && answers.isEmpty)
        let disk = try DeliveryLedger(location: f.managed.folder.appendingPathComponent("deliveries.json"))
        #expect(disk.record(id: "d_p2_cancel")?.discardedAt != nil)
        // A later queue behind the same unchanged draft reuses this episode's card,
        // but still waits 20 seconds before reopening it.
        _ = await f.runtime.sendUserMessage("Later", deliveryID: "d_p2_later")
        #expect(f.cards.card(id: card.id)?.status == .answered)
        try await wait20(f)
        #expect(f.cards.values.count == 1 && f.cards.card(id: card.id)?.status == .open)
    }

    @Test func confirmationIsScopedAndDecliningOrAnOldTokenDoesNotDiscard() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await ready(f)
        _ = await f.runtime.sendUserMessage("One", deliveryID: "d_p2_a")
        _ = await f.runtime.sendUserMessage("Two", deliveryID: "d_p2_b")
        try await wait20(f); let card = try notice(f)
        f.cards.respond(id: card.id, option: "cancel-draft-queue")
        let first = try #require(f.runtime.managedDraftCancellation)
        #expect(first.count == 2 && f.runtime.ledger?.records.allSatisfy { $0.discardedAt == nil } == true)
        f.runtime.respondToDraftCancellation(id: first.id, confirmed: false)
        #expect(f.runtime.ledger?.records.allSatisfy { $0.discardedAt == nil } == true)
        f.cards.respond(id: card.id, option: "cancel-draft-queue")
        let second = try #require(f.runtime.managedDraftCancellation)
        _ = await f.runtime.sendUserMessage("Arrives after confirmation", deliveryID: "d_p2_c")
        f.runtime.respondToDraftCancellation(id: first.id, confirmed: true)
        #expect(f.runtime.managedDraftCancellation?.id == second.id)
        f.runtime.respondToDraftCancellation(id: second.id, confirmed: true)
        #expect(f.runtime.ledger?.record(id: "d_p2_a")?.discardedAt != nil && f.runtime.ledger?.record(id: "d_p2_b")?.discardedAt != nil)
        #expect(f.runtime.ledger?.record(id: "d_p2_c")?.discardedAt == nil && f.cards.card(id: card.id)?.body.contains("holding 1 message") == true)
    }

    @Test func lateConfirmationCannotCancelMessagesAfterTheDraftClears() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await ready(f)
        for id in ["d_p2_a", "d_p2_b"] { _ = await f.runtime.sendUserMessage(id, deliveryID: id) }
        try await wait20(f); let card = try notice(f)
        f.cards.respond(id: card.id, option: "cancel-draft-queue")
        let confirmation = try #require(f.runtime.managedDraftCancellation)
        try await sample(f, managedSnapshot("claude-idle"))
        f.runtime.respondToDraftCancellation(id: confirmation.id, confirmed: true)
        #expect(f.runtime.managedDraftCancellation == nil && f.runtime.ledger?.records.allSatisfy { $0.discardedAt == nil } == true)
    }

    @Test func aQueuedOptionAnswerCancelsWithoutLosingItsHistoryOrInventingAnAck() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await ready(f)
        let key = try #require(f.managed.controller.sessionKey)
        let question = Card(kind: .question, body: "Which option?", options: [.init(id: "yes", label: "Yes")], sessionKey: key)
        f.cards.add(question); f.cards.respond(id: question.id, option: "yes", label: "Yes")
        let saved = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .reply })
        try await wait20(f); let card = try notice(f)
        #expect(card.body.contains("holding 1 message"))
        f.cards.respond(id: card.id, option: "cancel-draft-queue")
        #expect(f.runtime.ledger?.record(id: saved.delivery.id)?.discardedAt != nil)
        #expect(f.runtime.ledger?.record(id: saved.delivery.id)?.delivery.ackedAt == nil)
        #expect(f.cards.card(id: question.id)?.response?.optionID == "yes" && f.cards.card(id: question.id)?.status == .answered)
        #expect(f.cards.card(id: question.id)?.body.hasSuffix("Your queued answer was cancelled.") == true)
        #expect(f.runtime.responseJournal?.intents.isEmpty == true && f.tmux.deliveries.isEmpty)
    }

    @Test func aRepaintOrStaleSampleCannotCreateOrFalselyResolveTheAlert() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await ready(f)
        _ = await f.runtime.sendUserMessage("Saved", deliveryID: "d_p2_stale")
        f.managed.clock.advance(20, wake: false); f.runtime.processDueDeliveries()
        #expect(f.cards.values.isEmpty, "A stale screenshot is not new evidence of a human draft")
        try await sample(f, draft()); let card = try notice(f)
        try await sample(f, .init(screen: "", inputMetadata: "0|0|120|0|0"))
        #expect(f.cards.card(id: card.id)?.status == .open && f.runtime.managedDraftStatusDetail != nil)
        try await sample(f, managedSnapshot("claude-idle"))
        #expect(f.cards.card(id: card.id)?.status == .answered)
    }

    @Test func relaunchAdoptsThePersistedOpenNoticeInsteadOfPostingAnotherCard() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        let file = f.folder.appendingPathComponent("cards.json")
        let firstCards = CardStore(fileURL: file, clock: { f.clock.now })
        let connector = ManagedRecordingConnector(), routing = FakeRouting()
        func make(_ cards: CardStore) -> ZeusRuntime {
            .init(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: f.clock,
                socketPath: f.folder.appendingPathComponent("runtime.sock").path,
                ledgerURL: f.folder.appendingPathComponent("deliveries.json"), connectors: [connector], managedController: f.controller)
        }
        let first = make(firstCards)
        defer { first.stop() }
        try first.start(); try await f.settle(); try f.connectOwned()
        f.clock.advance(10, wake: false)
        await f.host.setSnapshot(try draft()); f.controller.refresh(); try await f.settle()
        _ = await first.sendUserMessage("Saved across launch", deliveryID: "d_p2_recovered")
        f.clock.advance(20, wake: false); f.controller.refresh(); try await f.settle()
        let old = try #require(firstCards.cards.first { $0.id.hasPrefix(ZeusRuntime.managedDraftPrefix) })
        first.stop()
        let cards = CardStore(fileURL: file, clock: { f.clock.now }), second = make(cards)
        defer { second.stop() }
        try second.start(); try await f.settle(); try f.connectOwned()
        // Adoption rechecks the pane and its PID/start identity before restoring the notice.
        f.clock.advance(10, wake: false); f.controller.refresh(); try await f.settle(); second.processDueDeliveries()
        #expect(cards.cards.count == 1 && cards.card(id: old.id)?.status == .open)
        #expect(second.managedDraftAlertCardID == old.id && second.managedDraftStatusDetail != nil)
        #expect(second.ledger?.record(id: "d_p2_recovered")?.delivery.attempts == 0 && connector.deliveries.isEmpty)
    }

    @Test func aPromptOrGhostSuggestionNeverCreatesADraftNotice() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        struct Frame: Decodable { let screen: String; let inputMetadata: String }
        let ghost = try JSONDecoder().decode(Frame.self, from: Data(contentsOf: root.appendingPathComponent("TestFixtures/panes/m8/claude-ghost-dark.json")))
        try await sample(f, .init(screen: ghost.screen, inputMetadata: ghost.inputMetadata))
        #expect(f.runtime.genuineManagedDraft() == nil)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        _ = await f.runtime.sendUserMessage("Wait", deliveryID: "d_p2_prompt")
        f.managed.clock.advance(30, wake: false); f.managed.controller.refresh(); try await f.managed.settle()
        #expect(!f.cards.values.contains { $0.id.hasPrefix(ZeusRuntime.managedDraftPrefix) })
    }

    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func boundedDraftExtractionProtectsTypedTextAndIgnoresPlaceholders(agent: AgentKind) throws {
        let before = try N1Messages.frame(agent, "three-lines-before")
        #expect(try N1Messages.snapshot(before).humanDraftText == nil)
        let typed: ManagedPaneSnapshot
        switch agent {
        case .claude: typed = try draft()
        case .codex: typed = .init(screen: "› A genuine human draft\n\narbitrary footer", inputMetadata: "23|0|120|0|1")
        case .opencode: typed = .init(screen: "  ┃\n  ┃  A genuine human draft\n  ┃\n  ┃  Build · Local fixture\n  ╹━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nctrl+p commands", inputMetadata: "26|1|120|0|1")
        case .other: Issue.record("Unsupported"); return
        }
        let input = try N1Messages.snapshot(typed)
        #expect(input.humanDraftText?.isEmpty == false && !input.isEmpty)
        #expect(ManagedPaneClassifier.classify(typed, agent: agent) == .idle)
    }

    @Test func journaledExhaustedLemonIsRecoveredWithoutAnAlertOrAnotherAttempt() async throws {
        let frame = try M8bClaudePasteTests().snapshot(), runner = LivePasteRunner(snapshot: try M8bClaudePasteTests().snapshot())
        let f = try ManagedDeliveryFixture(tmuxConnector: TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner))
        defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let pane = try #require(f.managed.controller.record?.pane), key = try #require(f.managed.controller.sessionKey)
        let delivery = Delivery(id: "d_8de2d3d3", kind: .userMessage, sessionKey: key,
            content: "Message from the user: Suggestion test 2: reply through Zeus with the word LEMON.",
            meta: ["tmux_paste_destination": pane.socket + ":" + pane.id], attempts: 5,
            failedAt: f.managed.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery, userText: "Suggestion test 2: reply through Zeus with the word LEMON."))
        try await sample(f, frame)
        try await eventually { f.runtime.ledger?.record(id: delivery.id)?.transportDeliveredAt != nil && f.runtime.sends.isEmpty }
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.attempts == 5)
        #expect(await runner.calls.filter { $0.contains("send-keys") }.count == 1)
        #expect(await runner.calls.allSatisfy { !$0.contains("paste-buffer") })
        #expect(!f.cards.values.contains { $0.id.hasPrefix(ZeusRuntime.managedDraftPrefix) })
    }
}
