import Foundation
import Testing
import ZeusDesign
@testable import Zeus

// D19: the first-run card points at connecting, the status strip and the assistant's control of Zeus, within 0.1.7's length.
@MainActor @Suite struct WelcomeCopyTests {
    @Test func welcomeCoversTheStripAndAppControlWithinItsBudget() {
        let card = WelcomeCard.make(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(card.body == WelcomeCard.body && card.body.count <= WelcomeCard.lengthBudget)
        #expect(card.body.contains("Connect it below"))
        #expect(card.body.contains("The line under the messages tells you what Zeus is waiting on."))
        #expect(card.body.contains("on by default") && card.body.contains("Settings\u{00A0}›\u{00A0}General"))
        #expect(card.body.components(separatedBy: "\n\n").count == 3, "one idea per paragraph")
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: card.body).isEmpty, "\(ZeusFonts.pixelFontMissingGlyphs(in: card.body))")
    }
}
