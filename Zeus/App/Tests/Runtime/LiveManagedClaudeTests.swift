import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

func liveClaudeIdleSnapshot() throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let raw = try String(contentsOf: root.appendingPathComponent("TestFixtures/live/m5-claude-idle-pane.txt"), encoding: .utf8)
    var lines = raw.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    let footer = lines.removeLast()
    let metadata = footer.split(separator: ",")
    try #require(metadata.count == 4)
    return .init(screen: lines.joined(separator: "\n") + "\n", inputMetadata: "\(metadata[0])|\(metadata[1])|\(metadata[2])|0|1")
}

private struct LiveCaptureRunner: ProcessRunning {
    let snapshot: ManagedPaneSnapshot
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        let result: String
        if arguments.contains("capture-pane") { result = snapshot.screen }
        else if arguments.contains("list-sessions") { result = "zeus\t$0\tfixture\n" }
        else if arguments.contains("show-options") { result = "fixture\n" }
        else if arguments.contains("list-panes") { result = "%0\n" }
        else if arguments.last?.contains("cursor_x") == true { result = snapshot.inputMetadata + "\n" }
        else if arguments.contains("display-message") { result = "zeus\t%0\t/tmp/live-fixture.sock\t1\t$0\t\(getpid())\t0\t\t\n" }
        else { result = "" }
        return .init(status: 0, stdout: Data(result.utf8))
    }
}

@MainActor
struct LiveManagedClaudeTests {
    @Test func developmentWarningBlocksWithUsefulLocalActionCopy() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let warning = ManagedPaneSnapshot(screen: """
            WARNING: Loading development channels
            Please use --channels to run approved channels.
            Channels: server:zeus
            ❯ 1. I am using this for local development
              2. Exit
            Enter to confirm
            """, inputMetadata: "0|3|120|0|0")
        guard case .blocked = ManagedPaneClassifier.classify(warning, agent: .claude) else { Issue.record("Warning wasn't recognized"); return }
        await f.managed.host.setSnapshot(warning)
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        let card = try #require(f.cards.values.first)
        #expect(card.body.contains("option 1") && card.body.contains("Zeus never chooses for you"))
        _ = await f.runtime.sendUserMessage("Hold during warning")
        #expect(f.tmux.deliveries.isEmpty && card.options.first?.id == "open-terminal")
        await f.managed.host.setSnapshot(try liveClaudeIdleSnapshot())
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.cards.card(id: card.id)?.body == "Answered in Terminal")
    }
    @Test func productionCapturePreservesRowsAndCustomStatuslineIdle() async throws {
        let snapshot = try liveClaudeIdleSnapshot()
        #expect(snapshot.screen.hasPrefix("\n"))
        #expect(ManagedPaneClassifier.classify(snapshot, agent: .claude) == .idle)
        let host = ManagedTmux(executable: URL(fileURLWithPath: "/bin/cat"), runner: LiveCaptureRunner(snapshot: snapshot), testSocket: "/tmp/live-fixture.sock")
        let lease = ManagedPane(name: "zeus", id: "%0", socket: "/tmp/live-fixture.sock", serverPID: 1, sessionNumber: "0", pid: Int(getpid()), startTime: 0, dead: false)
        let pane = try #require(try await host.inspect(name: "zeus", owner: "fixture", pane: lease))
        let captured = try await host.capture(pane, owner: "fixture")
        #expect(captured.screen == snapshot.screen)
        #expect(ManagedPaneClassifier.classify(captured, agent: .claude) == .idle)
        // Control: the pre-fix production trimming displaces the cursor row.
        let shifted = ManagedPaneSnapshot(screen: snapshot.screen.trimmingCharacters(in: .newlines), inputMetadata: snapshot.inputMetadata)
        #expect(ManagedPaneClassifier.classify(shifted, agent: .claude) == .unknown)
    }
    @Test func claudeSoftwareCaretIsIdleAndWrapsUpWithoutPermittingHumanEdits() throws {
        let metadata = Data("2|2|12|0|0".utf8)
        let before = try #require(TmuxInputSnapshot(metadata: metadata, screen: Data("\n────────────\n❯ \u{1b}[7m \u{1b}[0m\n────────────\ncustom statusline\n".utf8)))
        #expect(before.isEmpty && before.isProbablyIdle)
        let after = try #require(TmuxInputSnapshot(metadata: Data("10|3|12|0|0".utf8), screen: Data("────────────\n❯ 1234567890\n  ABCDEFGHIJ\n  KLmnopqr\u{1b}[7m \u{1b}[0m\n────────────\ncustom statusline\n".utf8)))
        #expect(after.containsOnlyPaste("1234567890ABCDEFGHIJKLmnopqr", after: before))
        #expect(!after.containsOnlyPaste("1234567890ABCDEFGHIJKLmnopq", after: before))
        #expect(TmuxInputSnapshot(metadata: Data("0|0|12|0|0".utf8), screen: Data("\n\n".utf8)) == nil)
        let live = try liveClaudeIdleSnapshot()
        let hidden = ManagedPaneSnapshot(screen: live.screen, inputMetadata: "2|31|120|0|0")
        #expect(ManagedPaneClassifier.classify(hidden, agent: .claude) == .idle)
    }
    @Test func claudeWordWrappedEnvelopeIsVerifiedInFull() throws {
        let rule = String(repeating: "─", count: 120)
        let before = try #require(TmuxInputSnapshot(metadata: Data("2|1|120|0|0".utf8), screen: Data("\(rule)\n❯ \u{1b}[7m \u{1b}[0m\n\(rule)\n  ⏸ manual mode on · ? for shortcuts · ← for agents\n".utf8)))
        let envelope = "[zeus delivery_id=d_2db5f5e4] Message from the user: Hello from the live composer fixture. (call zeus_ack with this delivery_id)"
        let screen = "\(rule)\n❯ [zeus delivery_id=d_2db5f5e4] Message from the user: Hello from the live composer fixture. (call zeus_ack with this\n  delivery_id)\u{1b}[7m \u{1b}[0m\n\(rule)\n  ⏸ manual mode on\n"
        let after = try #require(TmuxInputSnapshot(metadata: Data("14|2|120|0|0".utf8), screen: Data(screen.utf8)))
        #expect(after.containsOnlyPaste(envelope, after: before))
        #expect(!after.containsOnlyPaste(envelope + " human edit", after: before))
        let edited = try #require(TmuxInputSnapshot(metadata: Data("15|2|120|0|0".utf8), screen: Data(screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id)x").utf8)))
        #expect(!edited.containsOnlyPaste(envelope, after: before))
        #expect(!after.isEmpty)
        let hiddenDraft = try #require(TmuxInputSnapshot(metadata: Data("14|2|120|0|0".utf8), screen: Data((screen + "human input\n").utf8)))
        #expect(hiddenDraft.containsOnlyPaste(envelope, after: before), "Output beyond the bounded Claude input is not a draft")
    }
    @Test func liveIdleClearsConfirmedBlockAndReleasesQueuedMessage() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(try managedSnapshot("claude-trust"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        let id = try #require(f.runtime.managedBlockedCardID)
        _ = await f.runtime.sendUserMessage("Live capture control", deliveryID: "d_live_idle")
        #expect(f.tmux.deliveries.isEmpty)
        await f.managed.host.setSnapshot(try liveClaudeIdleSnapshot())
        f.managed.controller.refresh(); try await f.managed.settle()
        try await eventually { f.runtime.sends.isEmpty && f.tmux.deliveries.count == 1 }
        #expect(f.runtime.managedStatus == .running(.idle))
        #expect(f.cards.card(id: id)?.body == "Answered in Terminal")
        #expect(f.tmux.deliveries.first?.id == "d_live_idle")
    }
}
