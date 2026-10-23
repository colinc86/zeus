import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// A Claude pane that collapses Zeus's paste and ignores the first `swallow` Enters,
/// as when Claude is still settling the paste. Later Enters clear the input.
actor SwallowedEnterRunner: ProcessRunning {
    var frame: ManagedPaneSnapshot
    let empty: ManagedPaneSnapshot
    let pasted: ManagedPaneSnapshot
    var swallow: Int
    private(set) var enters = 0
    private(set) var calls: [[String]] = []
    init(empty: ManagedPaneSnapshot, pasted: ManagedPaneSnapshot, start: ManagedPaneSnapshot? = nil, swallow: Int) {
        self.empty = empty; self.pasted = pasted; frame = start ?? empty; self.swallow = swallow
    }
    func set(swallow value: Int) { swallow = value }
    func set(frame value: ManagedPaneSnapshot) { frame = value }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        calls.append(arguments)
        if arguments.contains("display-message") { return .init(status: 0, stdout: Data(frame.inputMetadata.utf8)) }
        if arguments.contains("capture-pane") { return .init(status: 0, stdout: Data(frame.screen.utf8)) }
        if arguments.contains("paste-buffer") { frame = pasted }
        if arguments.contains("send-keys"), arguments.last == "Enter" {
            enters += 1
            if enters > swallow, frame.screen == pasted.screen { frame = empty }
        }
        return .init(status: 0)
    }
    func mutations() -> [[String]] { calls.filter { $0.contains("load-buffer") || $0.contains("paste-buffer") || $0.contains("send-keys") } }
}

@MainActor
struct SwallowedEnterTests {
    static let fast = TmuxSubmitTiming(settle: .zero, window: .milliseconds(30), poll: .milliseconds(5), enters: 3, rounds: 3)
    static let label = "[Pasted text #1 +7 lines]"
    func frames() throws -> (empty: ManagedPaneSnapshot, pasted: ManagedPaneSnapshot) {
        (try N1Messages.frame(.claude, "eight-lines-before"), try N1Messages.frame(.claude, "eight-lines"))
    }
    /// The same composer holding someone else's paste of the same size.
    func otherPaste(_ pasted: ManagedPaneSnapshot) -> ManagedPaneSnapshot {
        .init(screen: pasted.screen.replacingOccurrences(of: "[Pasted text #1 +7 lines]", with: "[Pasted text #2 +7 lines]"), inputMetadata: pasted.inputMetadata)
    }
    struct Journal { var destinations: [String?] = []; var labels: [String] = []; var unconfirmed = 0 }
    func context(_ session: ConnectedSession, journal: @escaping (inout Journal) -> Void = { _ in }) -> (DeliveryRoutingContext, () -> Journal) {
        let settings = FakeRouting(); settings.deliveryMethod = .tmux
        let context = DeliveryRoutingContext(settings: settings, assistantSessionKey: nil, tmuxSocketPath: session.tmuxSocketPath)
        final class Box { var value = Journal() }
        let box = Box()
        context.confirmTmuxPaste = { box.value.destinations.append($0) }
        context.confirmTmuxPasteLabel = { box.value.labels.append($0) }
        context.noteUnconfirmedTmuxEnter = { box.value.unconfirmed += 1 }
        return (context, { box.value })
    }

    @Test func recordedLabelMatchesOnlyThatExactCollapsedPaste() throws {
        let (_, pasted) = try frames()
        let text = AgentInjectionText.format(N1Messages.delivery(1))
        let input = try N1Messages.snapshot(pasted)
        #expect(input.claudePasteLabel(for: text) == Self.label)
        #expect(input.containsRecordedClaudePasteLabel(Self.label, text: text))
        #expect(!input.containsRecordedClaudePasteLabel("[Pasted text #2 +7 lines]", text: text))
        #expect(!input.containsRecordedClaudePasteLabel(Self.label, text: text + "\nanother line"), "The line count must match Zeus's text")
        #expect(try !N1Messages.snapshot(otherPaste(pasted)).containsRecordedClaudePasteLabel(Self.label, text: text))
        #expect(input.claudePasteLabel(for: "single line") == nil)
    }

    @Test func swallowedFirstEnterIsPressedAgainAfterAFreshCheckAndConfirmed() async throws {
        let (empty, pasted) = try frames()
        let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, swallow: 1)
        let session = connectorSession(agent: .claude, pane: "%0")
        let (context, journal) = context(session)
        let delivery = N1Messages.delivery(1, sessionKey: session.sessionKey)
        try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner, timing: Self.fast)
            .deliver(delivery, to: session, bridge: nil, routing: context)
        #expect(await runner.enters == 2, "The first Enter left the paste in the input")
        #expect(await runner.mutations().filter { $0.contains("paste-buffer") }.count == 1)
        #expect(journal().labels == [Self.label], "The exact label is journaled before Enter")
        #expect(journal().destinations == ["/test/tmux.sock:%0", nil], "Ownership ends only after submission is confirmed")
        #expect(journal().unconfirmed == 0 && context.didSubmitRecordedTmuxPaste)
    }

    @Test func enterThatNeverTakesKeepsOwnershipAndRecoveryAfterRelaunchSubmitsIt() async throws {
        let (empty, pasted) = try frames()
        let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, swallow: .max)
        let session = connectorSession(agent: .claude, pane: "%0")
        let (context, journal) = context(session)
        var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey)
        await #expect(throws: TmuxPasteRecoveryError.unconfirmed) {
            try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner, timing: Self.fast)
                .deliver(delivery, to: session, bridge: nil, routing: context)
        }
        #expect(await runner.enters == Self.fast.enters, "Enter is retried a bounded number of times")
        #expect(journal().destinations == ["/test/tmux.sock:%0"], "Ownership is never dropped while Zeus's paste remains")
        #expect(journal().labels == [Self.label] && journal().unconfirmed == 1)
        #expect(!context.didSubmitRecordedTmuxPaste)

        // Relaunch: only the durable journal remains. The next Enter takes.
        await runner.set(swallow: 0)
        delivery.meta = ["tmux_paste_destination": "/test/tmux.sock:%0", "tmux_paste_label": Self.label, "tmux_enter_rounds": "1"]
        let (recovery, recovered) = self.context(session)
        recovery.onlySubmitRecordedTmuxPaste = true
        let before = await runner.mutations().count
        try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner, timing: Self.fast)
            .deliver(delivery, to: session, bridge: nil, routing: recovery)
        let after = await runner.mutations().dropFirst(before)
        #expect(after.map { $0.suffix(3) } == [["-t", "%0", "Enter"]], "Recovery only presses Enter; it never pastes again")
        #expect(recovered().destinations == [nil] && recovery.didSubmitRecordedTmuxPaste)
    }

    @Test func afterBoundedRoundsZeusStopsPressingEnterAndAsksTheUser() async throws {
        let (empty, pasted) = try frames()
        let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, start: pasted, swallow: .max)
        let session = connectorSession(agent: .claude, pane: "%0")
        var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey)
        delivery.meta = ["tmux_paste_destination": "/test/tmux.sock:%0", "tmux_paste_label": Self.label, "tmux_enter_rounds": "2"]
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner, timing: Self.fast)
        let (last, journal) = context(session)
        await #expect(throws: TmuxPasteRecoveryError.unsent) { try await connector.deliver(delivery, to: session, bridge: nil, routing: last) }
        #expect(journal().unconfirmed == 1 && journal().destinations.isEmpty)
        delivery.meta["tmux_enter_rounds"] = "3"
        let pressed = await runner.enters
        await #expect(throws: TmuxPasteRecoveryError.unsent) { try await connector.deliver(delivery, to: session, bridge: nil, routing: last) }
        #expect(await runner.enters == pressed, "Once the user is asked, Zeus no longer presses Enter")
    }

    @Test func aSameSizedPasteThatIsNotZeusRecordedLabelIsNeverSubmitted() async throws {
        let (empty, pasted) = try frames()
        let human = otherPaste(pasted)
        let session = connectorSession(agent: .claude, pane: "%0")
        for meta in [["tmux_paste_destination": "/test/tmux.sock:%0", "tmux_paste_label": Self.label],
                     ["tmux_paste_destination": "/test/tmux.sock:%0"], [:]] {
            let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, start: human, swallow: 0)
            var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey); delivery.meta = meta
            let (context, journal) = context(session)
            await #expect(throws: (any Error).self) {
                try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner, timing: Self.fast)
                    .deliver(delivery, to: session, bridge: nil, routing: context)
            }
            #expect(await runner.mutations().isEmpty, "A human paste is never loaded over, pasted into or submitted")
            #expect(journal().destinations.isEmpty)
        }
    }

    @Test func aHumanEditAfterAnUnconfirmedEnterIsLeftAloneAndReleased() async throws {
        let (empty, pasted) = try frames()
        let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, start: otherPaste(pasted), swallow: .max)
        let session = connectorSession(agent: .claude, pane: "%0")
        var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey)
        delivery.meta = ["tmux_paste_destination": "/test/tmux.sock:%0", "tmux_paste_label": Self.label, "tmux_enter_rounds": "1"]
        let (context, _) = context(session)
        await #expect(throws: ConnectorError.inputChanged) {
            try await TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner, timing: Self.fast)
                .deliver(delivery, to: session, bridge: nil, routing: context)
        }
        #expect(await runner.enters == 0)
    }

    // MARK: Runtime

    func sample(_ f: ManagedDeliveryFixture, _ frame: ManagedPaneSnapshot) async throws {
        await f.managed.host.setSnapshot(frame)
        f.managed.controller.refresh(); try await f.managed.settle()
        f.runtime.processDueDeliveries()
    }

    @Test func swallowedEnterKeepsTheJournalSoLaterMessagesAreNotHeldAsADraft() async throws {
        let (empty, pasted) = try frames()
        let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, swallow: .max)
        let f = try ManagedDeliveryFixture(tmuxConnector: TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner, timing: Self.fast))
        defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        let first = N1Messages.delivery(1, sessionKey: key)
        try f.runtime.ledger?.insert(.init(delivery: first, userText: first.content))
        f.runtime.processDueDeliveries()
        try await eventually { f.runtime.ledger?.record(id: first.id)?.delivery.meta["tmux_paste_label"] == Self.label && f.runtime.sends.isEmpty }
        let saved = try #require(f.runtime.ledger?.record(id: first.id))
        #expect(saved.delivery.meta["tmux_paste_destination"] != nil, "Zeus still owns its unsent paste")
        #expect(saved.transportDeliveredAt == nil && saved.delivery.ackedAt == nil)

        // The pane monitor now sees the collapsed paste. It is Zeus's, not the user's.
        try await sample(f, pasted)
        #expect(f.runtime.genuineManagedDraft() == nil)
        _ = await f.runtime.sendUserMessage("Later message", deliveryID: "d_later_one")
        let later = try #require(f.runtime.ledger?.record(id: "d_later_one"))
        #expect(!f.runtime.heldByManagedDraft(later))
        #expect(f.runtime.managedQueueReason(later) != "Your assistant's Terminal has unsent text. Zeus sends this once it's clear.")
        f.managed.clock.advance(21, wake: false); try await sample(f, pasted)
        #expect(!f.cards.values.contains { $0.id.hasPrefix(ZeusRuntime.managedDraftPrefix) }, "No human-draft alert for Zeus's own paste")

        // Claude accepts the next Enter: recovery submits the same paste, then the later message goes.
        await runner.set(swallow: 0)
        f.managed.clock.advance(6, wake: false); try await sample(f, pasted)
        try await eventually { f.runtime.ledger?.record(id: first.id)?.transportDeliveredAt != nil }
        #expect(f.runtime.ledger?.record(id: first.id)?.delivery.meta["tmux_paste_destination"] == nil)
        #expect(f.runtime.ledger?.record(id: first.id)?.delivery.meta["tmux_paste_label"] == nil)
        await runner.set(swallow: .max)
        try await sample(f, try N1Messages.frame(.claude, "eight-lines-before"))
        try await eventually { f.runtime.sends.isEmpty && f.runtime.ledger?.record(id: "d_later_one")?.delivery.meta["tmux_paste_destination"] != nil }
        #expect(await runner.mutations().filter { $0.contains("paste-buffer") }.count == 2, "The first paste was never pasted again")
    }

    @Test func unsentAfterBoundedRoundsAsksTheUserAndExplainsLaterMessages() async throws {
        let (empty, pasted) = try frames()
        let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, start: pasted, swallow: .max)
        let f = try ManagedDeliveryFixture(tmuxConnector: TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner, timing: Self.fast))
        defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let pane = try #require(f.managed.controller.record?.pane), key = try #require(f.managed.controller.sessionKey)
        var first = N1Messages.delivery(1, sessionKey: key)
        first.meta = ["tmux_paste_destination": pane.socket + ":" + pane.id, "tmux_paste_label": Self.label, "tmux_enter_rounds": "3"]
        first.attempts = 1
        try f.runtime.ledger?.insert(.init(delivery: first, userText: first.content))
        try await sample(f, pasted)
        try await eventually { f.runtime.ledger?.record(id: first.id)?.delivery.meta["tmux_unsent_paste"] == "true" && f.runtime.sends.isEmpty }
        #expect(await runner.enters == 0)
        _ = await f.runtime.sendUserMessage("Behind it", deliveryID: "d_behind")
        f.runtime.processDueDeliveries()
        #expect(f.runtime.ledger?.record(id: first.id)?.queueReason == TmuxPasteRecoveryError.unsent.localizedDescription)
        #expect(f.runtime.ledger?.record(id: "d_behind")?.queueReason == ZeusRuntime.waitingForEarlierPaste)
        #expect(f.runtime.genuineManagedDraft() == nil)
        // The user presses Enter in Terminal: the paste clears and Zeus's journal ends without another paste.
        await runner.set(frame: empty)
        f.managed.clock.advance(6, wake: false); try await sample(f, empty)
        try await eventually { f.runtime.ledger?.record(id: first.id)?.delivery.meta["tmux_paste_destination"] == nil }
        #expect(f.runtime.ledger?.record(id: first.id)?.delivery.meta["tmux_unsent_paste"] == nil)
        #expect(await !runner.calls.contains { $0.contains("load-buffer") && $0.contains("zeus-" + first.id) }, "Zeus's paste is never pasted again")
    }

    @Test func aLabelLeftByAnOlderZeusIsExplainedButNeverSubmitted() async throws {
        let (empty, pasted) = try frames()
        let runner = SwallowedEnterRunner(empty: empty, pasted: pasted, start: pasted, swallow: 0)
        let f = try ManagedDeliveryFixture(tmuxConnector: TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner, timing: Self.fast))
        defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        // Ownership was already lost: attempted once, no journal, label still in the input.
        var stuck = N1Messages.delivery(1, sessionKey: key)
        stuck.attempts = 1; stuck.lastAttemptAt = f.managed.clock.now
        try f.runtime.ledger?.insert(.init(delivery: stuck, userText: stuck.content))
        try await sample(f, pasted)
        f.managed.clock.advance(21, wake: false); try await sample(f, pasted)
        let card = try #require(f.cards.values.first { $0.id.hasPrefix(ZeusRuntime.managedDraftPrefix) })
        #expect(card.body.contains("This may be a message from Zeus that didn't send. Open Terminal and press Enter to send it, or clear it."))
        #expect(card.options.map(\.id) == ["open-terminal", "cancel-draft-queue"])
        #expect(await runner.mutations().isEmpty, "Zeus never submits an unproven paste")
        #expect(!ZeusRuntime.mayBeUnownedZeusPaste("[Pasted text #3 +2 lines]", queued: [.init(delivery: stuck)]))
        #expect(!ZeusRuntime.mayBeUnownedZeusPaste("A typed draft", queued: [.init(delivery: stuck)]))
    }
}
