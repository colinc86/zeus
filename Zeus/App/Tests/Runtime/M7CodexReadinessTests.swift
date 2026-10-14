import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

func m7CodexSnapshot() throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return .init(screen: try String(contentsOf: root.appendingPathComponent("TestFixtures/live/m7-codex-still-unsubmitted.ansi"), encoding: .utf8), inputMetadata: "64|36|120|0|1")
}

@MainActor
struct M7CodexReadinessTests {
    let envelope = "[zeus delivery_id=d_0bcebc84] Message from the user: Codex live test 2: reply through Zeus with the word GUAVA and the name of this folder. (call zeus_ack with this delivery_id)"
    @Test func warningFooterWithAnOwnedPasteIsIdleButNotEmpty() throws {
        let live = try m7CodexSnapshot()
        #expect(ManagedPaneClassifier.classify(live, agent: .codex) == .idle)
        let input = try #require(TmuxInputSnapshot(metadata: Data(live.inputMetadata.utf8), screen: Data(live.screen.utf8)))
        #expect(input.isProbablyIdle && !input.isEmpty)
        #expect(input.containsOnlyCodexPaste(envelope))
    }
    @Test(arguments: ["                                                                                               ⚠ 9 warnings · f2 to view", "  ? for shortcuts", "", "arbitrary footer\nno model or shortcuts\nadditional footer rows", "footer says esc to interrupt\nwould you like to run the following command?\nno, and tell codex\npress enter to confirm"])
    func warningAndShortcutFooterVariantsDoNotChangeInput(footer: String) throws {
        let live = try m7CodexSnapshot()
        var lines = live.screen.components(separatedBy: "\n")
        lines = Array(lines.prefix(38)) + footer.components(separatedBy: "\n")
        let screen = lines.joined(separator: "\n")
        let value = try #require(TmuxInputSnapshot(metadata: Data(live.inputMetadata.utf8), screen: Data(screen.utf8)))
        #expect(value.isProbablyIdle && value.containsOnlyCodexPaste(envelope) && !value.isEmpty)
        #expect(ManagedPaneClassifier.classify(.init(screen: screen, inputMetadata: live.inputMetadata), agent: .codex) == .idle)
        let atHome = try #require(TmuxInputSnapshot(metadata: Data("2|35|120|0|1".utf8), screen: Data(screen.utf8)))
        #expect(atHome.isProbablyIdle && !atHome.isEmpty)
        lines.insert("• Working (0s • esc to interrupt)", at: 35)
        #expect(ManagedPaneClassifier.classify(.init(screen: lines.joined(separator: "\n"), inputMetadata: "64|37|120|0|1"), agent: .codex) == .working)
        let edited = try #require(TmuxInputSnapshot(metadata: Data(live.inputMetadata.utf8), screen: Data(screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id) edited").utf8)))
        #expect(edited.isProbablyIdle && !edited.isEmpty && !edited.containsOnlyCodexPaste(envelope))
    }
    @Test func sampledPastePassesRuntimeGateButUnownedOrEditedTextCannotBeSent() async throws {
        let live = try m7CodexSnapshot()
        let runner = LivePasteRunner(snapshot: live)
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        // A journaled paste requires the actual recovery-capable connector.
        // The default recording fake can report sends but cannot recover input.
        let f = try ManagedDeliveryFixture(agent: .codex, tmuxConnector: connector); defer { f.cleanup() }
        await f.managed.finder.setID("native_m7")
        try await f.start(); try await f.idle()
        await f.managed.host.setSnapshot(live)
        f.managed.controller.refresh(); try await f.managed.settle()
        #expect(f.runtime.managedStatus == .running(.idle))
        let session = try #require(f.runtime.sessions.first)
        let pane = try #require(f.managed.controller.record?.pane)
        let destination = URL(fileURLWithPath: pane.socket).resolvingSymlinksInPath().standardizedFileURL.path + ":" + pane.id
        let delivery = Delivery(id: "d_0bcebc84", kind: .userMessage, sessionKey: session.sessionKey,
            content: "Message from the user: Codex live test 2: reply through Zeus with the word GUAVA and the name of this folder.", meta: ["tmux_paste_destination": destination])
        let context = try #require(f.runtime.transport(for: session.sessionKey, delivery: delivery)?.2)
        try await connector.deliver(delivery, to: session, bridge: nil, routing: context)
        #expect(await runner.calls.filter { $0.contains("send-keys") }.count == 1)
        #expect(await runner.calls.allSatisfy { !$0.contains("paste-buffer") })
        var unowned = delivery; unowned.meta.removeValue(forKey: "tmux_paste_destination")
        await #expect(throws: ConnectorError.inputBusy) { try await connector.deliver(unowned, to: session, bridge: nil, routing: context) }
        await runner.set(.init(screen: live.screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id)x"), inputMetadata: live.inputMetadata))
        await #expect(throws: ConnectorError.inputChanged) { try await connector.deliver(delivery, to: session, bridge: nil, routing: context) }
        #expect(await runner.calls.filter { $0.contains("send-keys") }.count == 1)
    }

    @Test func journaledPasteRequiresRecoveryCapableTransportEvenWhenCodexIsIdle() async throws {
        let f = try ManagedDeliveryFixture(agent: .codex); defer { f.cleanup() }
        await f.managed.finder.setID("native_m7_transport")
        try await f.start(); try await f.idle()
        let session = try #require(f.runtime.sessions.first)
        let delivery = Delivery(id: "d_owned_m7", kind: .userMessage, sessionKey: session.sessionKey,
            content: "Message from the user: Saved input", meta: ["tmux_paste_destination": "/test/tmux:%0"])
        #expect(f.runtime.managedStatus == .running(.idle))
        #expect(f.runtime.transport(for: session.sessionKey) != nil)
        #expect(f.runtime.transport(for: session.sessionKey, delivery: delivery) == nil,
            "A recording fake or channel must never consume a pending Terminal mutation")
    }
}
