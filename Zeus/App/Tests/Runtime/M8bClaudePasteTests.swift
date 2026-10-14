import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct M8bClaudePasteTests {
    func snapshot() throws -> ManagedPaneSnapshot {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return .init(screen: try String(contentsOf: root.appendingPathComponent("TestFixtures/live/m8b-suggestion-paste-fail.ansi"), encoding: .utf8), inputMetadata: "39|31|120|0|1")
    }
    @Test(arguments: ["0", "1"])
    func fullLemonEnvelopeMatchesTheRealCapture(cursor: String) throws {
        let screen = try snapshot().screen
        let input = try #require(TmuxInputSnapshot(metadata: Data("39|31|120|0|\(cursor)".utf8), screen: Data(screen.utf8)))
        let text = "[zeus delivery_id=d_8de2d3d3] Message from the user: Suggestion test 2: reply through Zeus with the word LEMON. (call zeus_ack with this delivery_id)"
        #expect(!input.isEmpty)
        #expect(input.containsOnlyClaudePaste(text))
        #expect(!input.containsOnlyClaudePaste(text + " edited"))
        let edited = try #require(TmuxInputSnapshot(metadata: Data("39|31|120|0|\(cursor)".utf8), screen: Data(screen.replacingOccurrences(of: "LEMON.", with: "LEMONx.").utf8)))
        #expect(!edited.containsOnlyClaudePaste(text))
    }
    @Test func retrySubmitsTheRecordedFullPasteWithoutPastingAgain() async throws {
        let runner = LivePasteRunner(snapshot: try snapshot())
        let routing = FakeRouting(); routing.deliveryMethod = .tmux
        let session = connectorSession(agent: .claude, pane: "%0", socket: "/test/tmux.sock")
        let delivery = Delivery(id: "d_8de2d3d3", kind: .userMessage, sessionKey: session.sessionKey,
            content: "Message from the user: Suggestion test 2: reply through Zeus with the word LEMON.",
            meta: ["tmux_paste_destination": "/test/tmux.sock:%0"])
        try await TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
            .deliver(delivery, to: session, bridge: nil, routing: routing)
        #expect(await runner.calls.filter { $0.contains("send-keys") }.count == 1)
        #expect(await runner.calls.allSatisfy { !$0.contains("paste-buffer") })
    }
}
