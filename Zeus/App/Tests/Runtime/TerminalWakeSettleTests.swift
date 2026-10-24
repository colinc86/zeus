import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct TerminalWakeSettleTests {
    @Test func tmuxDeliveryWaitsAFewSecondsAfterTheDisplayWakes() async throws {
        let (empty, pasted) = try TransientPaneFrameTests().frames()
        let runner = ScriptedClaudePane(empty: empty, pasted: pasted)
        let f = try ManagedDeliveryFixture(tmuxConnector: TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner, timing: TransientPaneFrameTests.fast))
        defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)

        // The display wakes; the user's first activity triggers a brief right away.
        f.runtime.noteTerminalMayResize()
        let brief = N1Messages.delivery(1, sessionKey: key)
        try f.runtime.ledger?.insert(.init(delivery: brief, userText: brief.content))
        f.runtime.processDueDeliveries()
        #expect(f.runtime.sends.isEmpty)
        f.managed.clock.advance(ZeusRuntime.terminalWakeSettle - 1, wake: false)
        f.runtime.processDueDeliveries()
        #expect(f.runtime.sends.isEmpty)
        #expect(await runner.mutations().isEmpty, "Nothing is typed while the Terminal may still be resizing")

        f.managed.clock.advance(1.5, wake: false)
        f.runtime.processDueDeliveries()
        try await eventually { f.runtime.sends.isEmpty && f.runtime.ledger?.record(id: brief.id)?.delivery.meta["tmux_paste_destination"] == nil
            && (f.runtime.ledger?.record(id: brief.id)?.delivery.attempts ?? 0) == 1 }
        #expect(await runner.enters == 1)
        #expect(await runner.mutations().filter { $0.contains("paste-buffer") }.count == 1)
    }
}
