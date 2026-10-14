import Testing
@testable import ZeusDesign

/// A4N-2: Auto says what it picks, and how.
struct ZeusSettingsCopyTests {
    typealias Auto = ZeusSettingsCopy.Auto

    @Test func autoNamesItsCurrentChoice() {
        #expect(Auto.title(current: "Claude · Website") == "Auto (Claude · Website)")
        #expect(Auto.title(current: nil) == "Auto")
        #expect(Auto.title(current: "") == "Auto")
        #expect(!Auto.title(current: nil).contains("newest"))
    }

    /// An older channel-capable Claude Code session beats a newer one without a channel; Codex is newest only.
    @Test func explanationMatchesThePolicy() {
        #expect(Auto.explanation(agent: "Claude Code", prefersDirect: true)
                == "Auto picks your newest Claude Code session that Zeus can message directly, or else your newest Claude Code session.")
        #expect(Auto.explanation(agent: "Codex", prefersDirect: false) == "Auto picks your newest Codex session.")
    }

    @Test func pixelFontCoversTheCopy() {
        for line in [Auto.title(current: "Claude · Website"), Auto.explanation(agent: "Claude Code", prefersDirect: true),
                     ZeusSettingsCopy.choosePanePlaceholder] {
            #expect(ZeusFonts.pixelFontMissingGlyphs(in: line).isEmpty, "\(line)")
        }
    }
}
