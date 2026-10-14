import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor struct PeekAccessibilityTests {
    @Test func explicitPeekLabelReadsMarkdownContentAndKeepsSpeakerAndTitle() {
        let body = "# Ready\n**Report** [open](https://example.invalid/report)\n> summary\n- first\n```swift\nlet result = 1\n```"
        let card = Card(kind: .message, title: "Update", body: body, sessionKey: "claude:/fixture#101.1000")
        let label = PeekContent.accessibilityDescription(card, choice: .pixel, palette: .for(.light))
        #expect(label.hasPrefix("Claude says: Update. Ready"))
        for text in ["Report open", "summary", "first", "let result = 1"] { #expect(label.contains(text)) }
        for syntax in ["# Ready", "**", "https://", "> summary", "- first", "```", "▌", "•"] { #expect(!label.contains(syntax)) }
    }
}
