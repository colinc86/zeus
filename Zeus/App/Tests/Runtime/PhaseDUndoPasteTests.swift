import Foundation
import Testing
@testable import Zeus

@MainActor struct PhaseDUndoPasteTests {
    @Test func exactUndoParagraphAtClaudeWrapBoundaryMatchesButEditsDoNot() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("TestFixtures/live/lm2d/undo-wrap-boundary.json"))
        let captured = try JSONDecoder().decode([String: String].self, from: data)
        let metadata = try #require(captured["inputMetadata"]), screen = try #require(captured["screen"])
        let input = try #require(TmuxInputSnapshot(metadata: Data(metadata.utf8), screen: Data(screen.utf8)))
        let text = "[zeus delivery_id=undo_rule_action_E282A515-1901-4044-A95D-A97F651A4B5E] The user pressed Undo. Reverse what you did for the rule “Keep synthetic updates concise”: Kept the synthetic recap concise. Restore the synthetic recap wording Say plainly if it cannot be reversed. (call zeus_ack with this delivery_id)"
        #expect(input.containsOnlyClaudePaste(text))
        #expect(!input.containsOnlyClaudePaste(text + " human edit"))
        #expect(!input.containsOnlyClaudePaste(text.replacingOccurrences(of: "wording", with: "text")))
        #expect(!input.isEmpty)
    }
}
