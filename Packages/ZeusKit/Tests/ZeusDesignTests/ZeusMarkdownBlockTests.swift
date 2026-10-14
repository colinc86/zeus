import SwiftUI
import Testing
@testable import ZeusDesign

/// F9 (DES-2 / PM-1): block markdown renders as readable blocks in one attributed string.
struct ZeusMarkdownBlockTests {
    static func render(_ md: String, _ choice: ZeusFontChoice = .pixel, _ palette: ZeusPalette = .light) -> AttributedString {
        ZeusMarkdown.style(md, choice: choice, palette: palette)
    }
    static func plain(_ md: String) -> String { String(render(md).characters) }

    @Test func plainAndInlineTextKeepsTheExactOldBehavior() {
        #expect(!ZeusMarkdown.hasBlockSyntax("Ship **v0.3** now.\nNext line,   spaced."))
        #expect(Self.plain("Ship **v0.3** now.\nNext line,   spaced.") == "Ship v0.3 now.\nNext line,   spaced.")
        #expect(Self.plain("**Part 1**\nThis is a long response.") == "**Part 1**\nThis is a long response.".replacingOccurrences(of: "**", with: ""))
        #expect(!ZeusMarkdown.hasBlockSyntax("Costs -5 dollars, 3.5 hours, #hashtag and a > b"))
    }

    @Test func bareAddressesAndMarkdownLinksAreClickableAndLookLikeLinks() {
        let text = Self.render("See https://example.com/docs, then [the PR](https://github.com/x/y/pull/1) and file:///tmp/report.pdf.")
        let links = text.runs.compactMap { run in run.link.map { ($0.absoluteString, String(text[run.range].characters), run) } }
        #expect(links.map(\.0) == ["https://example.com/docs", "https://github.com/x/y/pull/1", "file:///tmp/report.pdf"])
        #expect(links.map(\.1) == ["https://example.com/docs", "the PR", "file:///tmp/report.pdf"])
        #expect(links.allSatisfy { $0.2.foregroundColor == ZeusPalette.light.accent && $0.2.underlineStyle == .single })
        #expect(String(text.characters).hasSuffix("report.pdf."))   // the sentence's full stop stays outside the link
        // Addresses inside code stay plain, in inline and block markdown alike.
        #expect(Self.render("Run `curl https://example.com` now").runs.allSatisfy { $0.link == nil })
        #expect(Self.render("```\nhttps://example.com\n```").runs.allSatisfy { $0.link == nil })
        // A closing parenthesis that belongs to the address is kept.
        let wiki = Self.render("https://en.wikipedia.org/wiki/Zeus_(mythology) is open")
        #expect(wiki.runs.compactMap(\.link).map(\.absoluteString) == ["https://en.wikipedia.org/wiki/Zeus_(mythology)"])
    }

    @Test func headingsBecomeBoldLinesWithoutMarkers() {
        let text = Self.render("## Summary\nFixed the bug.")
        #expect(String(text.characters) == "Summary\nFixed the bug.")
        let heading = text.runs.first { String(text[$0.range].characters) == "Summary" }
        #expect(heading?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(heading?.foregroundColor == ZeusPalette.light.title)   // pixel: the gold accent
        let system = ZeusMarkdown.style("# Title", choice: .system, palette: .light)
        #expect(system.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true) // real bold
    }

    @Test func listsGetMarkersNestedIndentsAndTightSpacing() {
        let md = "- Updated `Auth.swift`\n- Added 3 tests\n  - one for expiry\n\n1. Review\n2. Merge"
        #expect(Self.plain(md) == "• Updated Auth.swift\n• Added 3 tests\n  – one for expiry\n\n1. Review\n2. Merge")
        let text = Self.render(md)
        let marker = text.runs.first { String(text[$0.range].characters) == "• " }
        #expect(marker?[ZeusMarkdown.DecorationAttribute.self] == true)
        #expect(marker?.foregroundColor == ZeusPalette.light.secondaryText)
    }

    @Test func fencedCodeKeepsLinesDropsTheLanguageTagAndIsOneTintedBlock() {
        let text = Self.render("Run this:\n\n```swift\nlet a = 1\n  let bb = 22\n```\nDone.")
        #expect(String(text.characters) == "Run this:\n\n let a = 1     \n   let bb = 22 \n\nDone.")
        #expect(!String(text.characters).contains("swift"))
        let codeRuns = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(codeRuns.allSatisfy { $0.backgroundColor == ZeusPalette.light.secondaryFill })
        // Every code line is padded to the same width, so the tint reads as one block.
        let lines = String(text.characters).split(separator: "\n").filter { $0.hasPrefix(" ") }
        #expect(Set(lines.map(\.count)).count == 1)
    }

    @Test func quotesGetABarAndSecondaryText() {
        let text = Self.render("> Staging needs\n> a redeploy.")
        #expect(String(text.characters) == "▌ Staging needs\n▌ a redeploy.")
        let body = text.runs.first { String(text[$0.range].characters).contains("Staging") }
        #expect(body?.foregroundColor == ZeusPalette.light.secondaryText)
    }

    @Test func paragraphsKeepAgentLineBreaksAndBlankLinesBetweenBlocks() {
        #expect(Self.plain("# Plan\nLine one\nline two\n\nNext paragraph.") == "Plan\nLine one\nline two\n\nNext paragraph.")
        #expect(ZeusMarkdown.preservingLineBreaks("a\n```\nx\n```\nb") == "a  \n```\nx\n```\nb  ")
    }

    @Test func tablesAndRulesUseGlyphsThePixelFontHas() {
        #expect(Self.plain("| A | B |\n|---|---|\n| 1 | 2 |") == "A │ B\n1 │ 2")
        #expect(Self.plain("Above\n\n---\n\nBelow") == "Above\n\n" + String(repeating: "─", count: 12) + "\n\nBelow")
    }

    @Test func emphasisStaysVisibleInThePixelFont() {
        let text = Self.render("an *important* word")
        let run = text.runs.first { String(text[$0.range].characters) == "important" }
        #expect(run?.foregroundColor == ZeusPalette.light.secondaryText)
        let system = ZeusMarkdown.style("an *important* word", choice: .system, palette: .light)
        #expect(system.runs.first { String(system[$0.range].characters) == "important" }?.foregroundColor == nil)
    }

    @Test func spokenTextDropsDecorations() {
        let text = Self.render("> Note\n\n- one\n\n```\ncode\n```")
        #expect(ZeusMarkdown.spokenText(text) == "Note\n\none\n\ncode")
    }

    @Test func everyDecorationGlyphIsInThePixelFont() throws {
        let text = Self.render("> q\n\n- a\n  - b\n1. c\n\n| x | y |\n|---|---|\n\n---")
        let decorations = text.runs.filter { $0[ZeusMarkdown.DecorationAttribute.self] == true }
            .map { String(text[$0.range].characters) }.joined()
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: decorations).isEmpty)
    }
}

extension ZeusMarkdownBlockTests {
    @Test func peekTypesTheRenderedTextNotTheSyntax() {
        let md = "## Done\n- one\n- two"
        #expect(ZeusPeekTiming.typedLength(md) == "Done\n• one\n• two".count)
        #expect(ZeusPeekTiming.typedLength("**hi** there") == "hi there".count)
    }
}
