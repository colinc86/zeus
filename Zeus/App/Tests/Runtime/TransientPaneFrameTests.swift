import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// A Claude pane driven by a script, built from the real N1 Claude captures. Each
/// read is a display-message (which advances the script) plus a capture-pane of the
/// same frame. After the Enter numbered `submitAt` or later the input clears and stays
/// clear; earlier Enters are swallowed. `transients[n]` are shown for one read each
/// after Enter `n`, as when a resize or repaint redraws the agent.
actor ScriptedClaudePane: ProcessRunning {
    struct Plan: Sendable {
        var submitAt = 1
        var transients: [Int: [ManagedPaneSnapshot]] = [:]
        /// Where a swallowed Enter leaves the pane (default: unchanged).
        var afterSwallow: ManagedPaneSnapshot?
        /// The pane resizes right before the paste, or while Zeus pastes.
        var onLoadBuffer: ManagedPaneSnapshot?
        var onPaste: ManagedPaneSnapshot?
        /// After load-buffer, every read reports a different height.
        var flapAfterLoad = false
    }
    let empty: ManagedPaneSnapshot
    let pasted: ManagedPaneSnapshot
    var frame: ManagedPaneSnapshot
    var plan: Plan
    private var queue: [ManagedPaneSnapshot] = []
    private var shown: ManagedPaneSnapshot
    private var flap = false, reads = 0
    private(set) var enters = 0
    private(set) var calls: [(at: ContinuousClock.Instant, arguments: [String])] = []
    init(empty: ManagedPaneSnapshot, pasted: ManagedPaneSnapshot, start: ManagedPaneSnapshot? = nil, plan: Plan = .init()) {
        self.empty = empty; self.pasted = pasted; frame = start ?? empty; shown = start ?? empty; self.plan = plan
    }
    func set(frame value: ManagedPaneSnapshot) { frame = value }
    func set(submitAt value: Int) { plan.submitAt = value }
    func set(afterSwallow value: ManagedPaneSnapshot?) { plan.afterSwallow = value }
    /// Frames shown for one read each before the settled frame.
    func show(_ frames: [ManagedPaneSnapshot]) { queue = frames }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        calls.append((.now, arguments))
        if arguments.contains("display-message") {
            reads += 1
            shown = queue.isEmpty ? frame : queue.removeFirst()
            if flap { shown = Self.sized(shown, height: 30 + reads % 2) }
            // Answer only the fields asked for, as tmux does.
            let fields = (arguments.last ?? "").components(separatedBy: "|").count
            let metadata = shown.inputMetadata.trimmingCharacters(in: .newlines).components(separatedBy: "|").prefix(fields).joined(separator: "|")
            return .init(status: 0, stdout: Data((metadata + "\n").utf8))
        }
        if arguments.contains("capture-pane") { return .init(status: 0, stdout: Data(shown.screen.utf8)) }
        if arguments.contains("load-buffer") {
            if let resized = plan.onLoadBuffer { frame = resized }
            if plan.flapAfterLoad { flap = true }
        }
        if arguments.contains("paste-buffer") { frame = plan.onPaste ?? pasted }
        if arguments.contains("send-keys"), arguments.last == "Enter" {
            enters += 1
            if enters >= plan.submitAt { frame = empty } else if let settled = plan.afterSwallow { frame = settled }
            queue = plan.transients[enters] ?? []
        }
        return .init(status: 0)
    }
    func mutations() -> [[String]] { calls.map(\.arguments).filter { $0.contains("load-buffer") || $0.contains("paste-buffer") || $0.contains("send-keys") } }
    func firstCall(_ name: String) -> ContinuousClock.Instant? {
        calls.first { $0.arguments.contains(name) && (name != "send-keys" || $0.arguments.last == "Enter") }?.at
    }
    /// The same frame with the pane height tmux reports.
    static func sized(_ frame: ManagedPaneSnapshot, height: Int) -> ManagedPaneSnapshot {
        var fields = frame.inputMetadata.trimmingCharacters(in: .newlines).components(separatedBy: "|")
        while fields.count < 6 { fields.append("") }
        return .init(screen: frame.screen, inputMetadata: fields.prefix(6).joined(separator: "|") + "|\(height)")
    }
}

@MainActor
struct TransientPaneFrameTests {
    static let fast = TmuxSubmitTiming(settle: .zero, window: .milliseconds(30), poll: .milliseconds(5), enters: 3, rounds: 3,
        confirmSpan: .milliseconds(40), confirmSamples: 3, geometrySettle: .milliseconds(80), settleLimit: .milliseconds(400))
    static let label = SwallowedEnterTests.label
    static let destination = "/test/tmux.sock:%0"

    enum Transient: String, CaseIterable, Sendable { case blankComposer, resizedBlankComposer, working, otherInput }
    func frames() throws -> (empty: ManagedPaneSnapshot, pasted: ManagedPaneSnapshot) {
        (ScriptedClaudePane.sized(try N1Messages.frame(.claude, "eight-lines-before"), height: 40),
         ScriptedClaudePane.sized(try N1Messages.frame(.claude, "eight-lines"), height: 40))
    }
    func frame(_ kind: Transient) throws -> ManagedPaneSnapshot {
        let (empty, pasted) = try frames()
        switch kind {
        case .blankComposer: return empty
        case .resizedBlankComposer: return ScriptedClaudePane.sized(empty, height: 38)
        case .working:
            // Mid-redraw: no composer yet, only Claude's interrupt hint. Classified as working.
            let screen = Array(repeating: "", count: 38).joined(separator: "\n") + "\n✻ Thinking… (esc to interrupt)\n"
            let value = ManagedPaneSnapshot(screen: screen, inputMetadata: "0|0|120|0|0||40")
            #expect(ManagedPaneClassifier.classify(value, agent: .claude) == .working)
            return value
        case .otherInput: return SwallowedEnterTests().otherPaste(pasted)
        }
    }
    func connector(_ runner: ScriptedClaudePane, timing: TmuxSubmitTiming = Self.fast) -> TmuxConnector {
        TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner, timing: timing)
    }
    func context(_ session: ConnectedSession, recovery: Bool = false) -> (DeliveryRoutingContext, () -> SwallowedEnterTests.Journal) {
        let (value, journal) = SwallowedEnterTests().context(session)
        value.onlySubmitRecordedTmuxPaste = recovery
        return (value, journal)
    }
    func recorded(_ rounds: Int = 1) -> [String: String] {
        ["tmux_paste_destination": Self.destination, "tmux_paste_label": Self.label, "tmux_enter_rounds": String(rounds)]
    }

    // MARK: After Enter

    @Test(arguments: Transient.allCases)
    func aTransientFrameAfterEnterNeverEndsOwnership(_ kind: Transient) async throws {
        let (empty, pasted) = try frames()
        let transient = try frame(kind)
        // The first Enter is swallowed while the pane redraws; the label comes back.
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, plan: .init(submitAt: 2, transients: [1: [transient]]))
        let session = connectorSession(agent: .claude, pane: "%0")
        let (context, journal) = context(session)
        try await connector(runner).deliver(N1Messages.delivery(1, sessionKey: session.sessionKey), to: session, bridge: nil, routing: context)
        #expect(await runner.enters == 2, "One \(kind) frame is not proof that Enter submitted")
        #expect(journal().labels == [Self.label])
        #expect(journal().destinations == [Self.destination, nil], "Ownership ends only after the second Enter really cleared the input")
        #expect(context.didSubmitRecordedTmuxPaste)
    }

    @Test(arguments: Transient.allCases)
    func aTransientFrameThenTheLabelKeepsOwnershipAndRecoverySubmitsIt(_ kind: Transient) async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, plan: .init(submitAt: .max, transients: [1: [try frame(kind)]]))
        let session = connectorSession(agent: .claude, pane: "%0")
        let (fresh, journal) = context(session)
        var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey)
        await #expect(throws: TmuxPasteRecoveryError.unconfirmed) {
            try await connector(runner).deliver(delivery, to: session, bridge: nil, routing: fresh)
        }
        #expect(journal().destinations == [Self.destination], "Ownership is kept while Zeus's label is still in the input")
        #expect(journal().labels == [Self.label] && journal().unconfirmed == 1)
        #expect(!fresh.didSubmitRecordedTmuxPaste)

        // Recovery after a relaunch: only the journal remains. The next Enter takes.
        await runner.set(submitAt: await runner.enters + 1)
        delivery.meta = recorded()
        let (recovery, recovered) = context(session, recovery: true)
        let before = await runner.mutations().count
        try await connector(runner).deliver(delivery, to: session, bridge: nil, routing: recovery)
        #expect(await runner.mutations().dropFirst(before).map { $0.suffix(3) } == [["-t", "%0", "Enter"]], "Recovery only presses Enter")
        #expect(recovered().destinations == [nil] && recovery.didSubmitRecordedTmuxPaste)
    }

    @Test func differentInputAfterEnterIsNeverSubmittedAndOwnershipStays() async throws {
        let (empty, pasted) = try frames()
        let other = try frame(.otherInput)
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, plan: .init(submitAt: .max, afterSwallow: other))
        let session = connectorSession(agent: .claude, pane: "%0")
        let (fresh, journal) = context(session)
        var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey)
        await #expect(throws: TmuxPasteRecoveryError.unconfirmed) {
            try await connector(runner).deliver(delivery, to: session, bridge: nil, routing: fresh)
        }
        #expect(await runner.enters == 1, "Zeus presses nothing into input it can't prove is its own")
        #expect(journal().destinations == [Self.destination] && journal().labels == [Self.label])
        #expect(!fresh.didSubmitRecordedTmuxPaste)

        // While the input stays different, recovery never presses Enter and keeps ownership.
        delivery.meta = recorded()
        for _ in 0..<2 {
            let (recovery, recovered) = context(session, recovery: true)
            await #expect(throws: ConnectorError.inputChanged) {
                try await connector(runner).deliver(delivery, to: session, bridge: nil, routing: recovery)
            }
            #expect(recovered().destinations.isEmpty)
        }
        #expect(await runner.enters == 1)

        // The input shows exactly Zeus's recorded label again: recovery submits it.
        await runner.set(frame: pasted); await runner.set(afterSwallow: nil); await runner.set(submitAt: 2)
        let (recovery, recovered) = context(session, recovery: true)
        try await connector(runner).deliver(delivery, to: session, bridge: nil, routing: recovery)
        #expect(await runner.enters == 2)
        #expect(recovered().destinations == [nil] && recovery.didSubmitRecordedTmuxPaste)
        #expect(await runner.mutations().filter { $0.contains("paste-buffer") }.count == 1, "Never pasted again")
    }

    @Test func oneEmptyReadDuringRecoveryDoesNotReleaseTheRecordedPaste() async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, start: pasted, plan: .init(submitAt: 1))
        await runner.show([empty])
        let session = connectorSession(agent: .claude, pane: "%0")
        var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey); delivery.meta = recorded()
        let (recovery, recovered) = context(session, recovery: true)
        try await connector(runner).deliver(delivery, to: session, bridge: nil, routing: recovery)
        #expect(await runner.enters == 1, "The label came back, so recovery pressed Enter")
        #expect(recovered().destinations == [nil] && recovery.didSubmitRecordedTmuxPaste)
    }

    @Test func emptyInputThatStaysEmptyDuringRecoveryReleasesWithoutPressing() async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, start: empty)
        let session = connectorSession(agent: .claude, pane: "%0")
        var delivery = N1Messages.delivery(1, sessionKey: session.sessionKey); delivery.meta = recorded()
        let (recovery, recovered) = context(session, recovery: true)
        await #expect(throws: TmuxPasteRecoveryError.absent) {
            try await connector(runner).deliver(delivery, to: session, bridge: nil, routing: recovery)
        }
        #expect(recovered().destinations == [nil] && !recovery.didSubmitRecordedTmuxPaste)
        #expect(await runner.mutations().isEmpty)
    }

    @Test func realSubmissionStillConfirmsPromptlyWithProductionTiming() async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted)
        let session = connectorSession(agent: .claude, pane: "%0")
        let (context, journal) = context(session)
        let start = ContinuousClock.now
        try await connector(runner, timing: .standard).deliver(N1Messages.delivery(1, sessionKey: session.sessionKey), to: session, bridge: nil, routing: context)
        let elapsed = ContinuousClock.now - start
        #expect(await runner.enters == 1)
        #expect(journal().destinations == [Self.destination, nil] && context.didSubmitRecordedTmuxPaste)
        #expect(elapsed >= TmuxSubmitTiming.standard.confirmSpan, "Submission is proven by a sustained clear input")
        #expect(elapsed < .seconds(3))
    }

    // MARK: Resizing pane

    @Test func aPaneResizedRightBeforeThePasteSettlesFirst() async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: ScriptedClaudePane.sized(pasted, height: 38),
            plan: .init(onLoadBuffer: ScriptedClaudePane.sized(empty, height: 38)))
        let session = connectorSession(agent: .claude, pane: "%0")
        let (context, journal) = context(session)
        try await connector(runner).deliver(N1Messages.delivery(1, sessionKey: session.sessionKey), to: session, bridge: nil, routing: context)
        let resized = try #require(await runner.firstCall("load-buffer")), paste = try #require(await runner.firstCall("paste-buffer"))
        #expect(paste - resized >= Self.fast.geometrySettle, "Zeus waited for a stable pane size before pasting")
        #expect(journal().destinations == [Self.destination, nil])
    }

    @Test func aPaneResizedWhileZeusPastesSettlesBeforeEnter() async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, plan: .init(onPaste: ScriptedClaudePane.sized(pasted, height: 38)))
        let session = connectorSession(agent: .claude, pane: "%0")
        let (context, journal) = context(session)
        try await connector(runner).deliver(N1Messages.delivery(1, sessionKey: session.sessionKey), to: session, bridge: nil, routing: context)
        let paste = try #require(await runner.firstCall("paste-buffer")), enter = try #require(await runner.firstCall("send-keys"))
        #expect(enter - paste >= Self.fast.geometrySettle, "Zeus waited for a stable pane size before Enter")
        #expect(journal().destinations == [Self.destination, nil] && context.didSubmitRecordedTmuxPaste)
    }

    @Test func aPaneThatKeepsResizingIsNotPastedInto() async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, plan: .init(flapAfterLoad: true))
        let session = connectorSession(agent: .claude, pane: "%0")
        let (context, journal) = context(session)
        await #expect(throws: ConnectorError.inputBusy) {
            try await connector(runner).deliver(N1Messages.delivery(1, sessionKey: session.sessionKey), to: session, bridge: nil, routing: context)
        }
        #expect(await runner.mutations().filter { $0.contains("paste-buffer") || $0.contains("send-keys") }.isEmpty)
        #expect(journal().destinations.isEmpty && !context.didMutateTmuxInput, "Nothing was typed, so the delivery is simply postponed")
    }

    // MARK: Runtime

    func sample(_ f: ManagedDeliveryFixture, _ frame: ManagedPaneSnapshot) async throws {
        await f.managed.host.setSnapshot(frame)
        f.managed.controller.refresh(); try await f.managed.settle()
        f.runtime.processDueDeliveries()
    }

    @Test func aBlankFrameAfterEnterNeverMakesZeusPasteLookLikeTheUsersDraft() async throws {
        let (empty, pasted) = try frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, plan: .init(submitAt: .max, transients: [1: [empty, empty]]))
        let f = try ManagedDeliveryFixture(tmuxConnector: TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner, timing: Self.fast))
        defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        let brief = N1Messages.delivery(1, sessionKey: key)
        try f.runtime.ledger?.insert(.init(delivery: brief, userText: brief.content))
        f.runtime.processDueDeliveries()
        try await eventually { f.runtime.ledger?.record(id: brief.id)?.delivery.meta["tmux_enter_rounds"] == "1" && f.runtime.sends.isEmpty }
        let saved = try #require(f.runtime.ledger?.record(id: brief.id))
        #expect(saved.delivery.meta["tmux_paste_destination"] != nil && saved.delivery.meta["tmux_paste_label"] == Self.label)
        #expect(saved.transportDeliveredAt == nil)

        // The monitor sees Zeus's label: no draft hold, no draft alert.
        try await sample(f, pasted)
        #expect(f.runtime.genuineManagedDraft() == nil)
        _ = await f.runtime.sendUserMessage("Later message", deliveryID: "d_later_two")
        let later = try #require(f.runtime.ledger?.record(id: "d_later_two"))
        #expect(!f.runtime.heldByManagedDraft(later))
        f.managed.clock.advance(21, wake: false); try await sample(f, pasted)
        #expect(!f.cards.values.contains { $0.id.hasPrefix(ZeusRuntime.managedDraftPrefix) })

        // Recovery presses Enter on the recorded label and confirms it.
        await runner.set(submitAt: await runner.enters + 1)
        f.managed.clock.advance(6, wake: false); try await sample(f, pasted)
        try await eventually { f.runtime.ledger?.record(id: brief.id)?.transportDeliveredAt != nil }
        #expect(await runner.calls.filter { $0.arguments.contains("paste-buffer") && $0.arguments.contains("zeus-" + brief.id) }.count == 1)
    }

    @Test func differentInputAfterEnterFollowsTheHumanDraftPathWithoutSubmitting() async throws {
        let (empty, pasted) = try frames()
        let other = try frame(.otherInput)
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted, plan: .init(submitAt: .max, afterSwallow: other))
        let f = try ManagedDeliveryFixture(tmuxConnector: TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner, timing: Self.fast))
        defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        let brief = N1Messages.delivery(1, sessionKey: key)
        try f.runtime.ledger?.insert(.init(delivery: brief, userText: brief.content))
        f.runtime.processDueDeliveries()
        try await eventually { f.runtime.ledger?.record(id: brief.id)?.delivery.meta["tmux_enter_rounds"] == "1" && f.runtime.sends.isEmpty }
        try await sample(f, other)
        #expect(f.runtime.genuineManagedDraft()?.1 == "[Pasted text #2 +7 lines]", "The different input is the user's draft")
        _ = await f.runtime.sendUserMessage("Later message", deliveryID: "d_later_three")
        #expect(f.runtime.heldByManagedDraft(try #require(f.runtime.ledger?.record(id: "d_later_three"))))
        f.managed.clock.advance(6, wake: false); try await sample(f, other)
        f.managed.clock.advance(6, wake: false); try await sample(f, other)
        try await eventually { f.runtime.sends.isEmpty }
        #expect(await runner.enters == 1, "Zeus never presses Enter on input it can't prove is its own")
        #expect(f.runtime.ledger?.record(id: brief.id)?.delivery.meta["tmux_paste_label"] == Self.label)
        #expect(f.runtime.ledger?.record(id: brief.id)?.transportDeliveredAt == nil)
    }
}
