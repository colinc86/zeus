import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

struct DesignFollowupTests {
    @Test func messageAccessibilityUsesContentWithoutMarkdownDecorations() {
        let markdown = ZeusMarkdown.attributed("## Summary\n- First item\n> Quoted content", choice: .pixel, palette: .lightHighContrast)
        #expect(String(markdown.characters).contains("▌"))
        let view = MessageBodyView(markdown: markdown, active: false, enabled: false, soundEnabled: false, reveal: nil)
        #expect(view.accessibilityText.contains("Summary") && view.accessibilityText.contains("Quoted content"))
        #expect(!view.accessibilityText.contains("▌") && !view.accessibilityText.contains("•"))
    }
    @Test func shortcutDescriptionUsesModifierNamesInMacOrder() {
        var key = TalkHotKey(); key.control = true; key.shift = true
        #expect(key.displayName == "Control + Option + Shift + Command + Z")
    }
}
