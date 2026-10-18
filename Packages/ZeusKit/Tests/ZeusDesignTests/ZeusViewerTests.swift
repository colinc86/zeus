import SwiftUI
import Testing
@testable import ZeusDesign

/// DV1: the document viewer's chrome, copy and the Markdown document layout (CONVERSATION.md §21).
@MainActor
struct ZeusViewerTests {
    @Test func headerCopyAndIcons() {
        #expect(ZeusViewerHeaderModel.openTitle(app: "Keynote") == "Open in Keynote")
        #expect(ZeusViewerHeaderModel.openTitle(app: nil) == "Open")
        let model = ZeusViewerHeaderModel(title: "Q3 Planning.md", location: "~/Documents/Talks", openTitle: "Open in Keynote",
                                          step: .init(index: 2, count: 3))
        #expect(model.openTooltip == "Open in Keynote (⌘O)")
        #expect(model.expandTitle == "Expand" && model.expandIcon == .expand)
        var expanded = model; expanded.expanded = true
        #expect(expanded.expandTooltip == "Collapse (⌃⌘F)" && expanded.expandIcon == .collapse)
        #expect(model.step?.text == "2/3")
        #expect(model.step?.hasPrevious == true && model.step?.hasNext == true)
        #expect(ZeusViewerHeaderModel.Step(index: 1, count: 1).hasPrevious == false)
        #expect(ZeusViewerHeaderModel.Step(index: 3, count: 3).hasNext == false)
        for icon in ZeusViewerHeaderModel.Icon.allCases {
            #expect(icon.rows.count == 12 && icon.rows.allSatisfy { $0.count == 12 }, "\(icon)")
        }
    }

    @Test func readOnlySnapshotHeaderKeepsNavigationWithoutOpen() throws {
        let model = ZeusViewerHeaderModel(title: "Evening reflection · Fri 17 Oct", openTitle: "Open",
                                          canOpen: false, canReveal: false)
        #expect(!model.canOpen && !model.canReveal)
        #expect(model.backTitle == "Messages" && model.expandTitle == "Expand")
        #expect(ZeusViewerHeaderModel(title: "File", openTitle: "Open").canOpen)
        let header = ZeusViewerHeader(model, menu: [.init("Copy Text"), .init("Find…")],
                                      onBack: {}, onOpen: {}, onReveal: {}, onExpand: {}).frame(width: 348)
        #expect(ImageRenderer(content: header).cgImage != nil)
    }

    @Test func statusCopyAndFindCount() {
        #expect(ZeusViewerStatus.Copy.detail(kind: "Keynote", size: "1.2 MB", modified: "Today 8:02") == "Keynote · 1.2 MB · Modified Today 8:02")
        #expect(ZeusViewerStatus.Copy.detail(kind: nil, size: nil, modified: nil) == nil)
        #expect(ZeusViewerStatus.Copy.openForRest(app: "BBEdit") == "Open in BBEdit for the rest.")
        #expect(ZeusViewerStatus.Copy.sizeLimit == 5_000_000 && ZeusViewerStatus.Copy.tooLarge == "Showing the first 5 MB.")
        #expect(ZeusFolderRow.moreCaption(212) == "and 212 more · Show in Finder")
        #expect(ZeusFolderRow.columnWidth(ZeusFolderRow.modifiedColumnWidth, choice: .pixel, scale: .default) == 76)
        #expect(ZeusFolderRow.columnWidth(ZeusFolderRow.modifiedColumnWidth, choice: .pixel, scale: .larger) == 114)
        #expect(ZeusFindBar.countText(current: 2, total: 7) == "2 of 7")
        #expect(ZeusFindBar.countText(current: 0, total: 0) == "No matches")
        #expect(ZeusFindBar.countText(current: 0, total: nil) == nil)
        #expect(ZeusViewerContextLine.pageText(3, of: 12) == "Page 3 of 12")
        #expect(ZeusMarkdown.role(forHeadingLevel: 1) == .title && ZeusMarkdown.role(forHeadingLevel: 2) == .body)
        typealias Copy = ZeusViewerStatus.Copy
        let strings = [Copy.unsupported, Copy.missing, Copy.unreadable, Copy.unreadableFolder, Copy.emptyFile, Copy.emptyFolder,
                       Copy.loading, Copy.revealOnly, Copy.tooLarge, ZeusViewerHeaderModel.messagesBackTitle, ZeusFindBar.noMatches]
        for text in strings { #expect(ZeusFonts.pixelFontMissingGlyphs(in: text).isEmpty, "\(text)") }
    }

    @Test func fontSizesAndNativeFontsAreExposedForNativeHosts() {
        #expect(ZeusTextRole.title.size(for: .pixel) == 16.5)
        #expect(ZeusTextRole.body.size(for: .system, scale: .larger) == 17)
        ZeusFonts.registerBundled()
        let pixel = ZeusFonts.ctFont(.body, choice: .pixel)
        #expect(CTFontGetSize(pixel) == 11)
        let system = ZeusFonts.ctFont(.title, choice: .system, scale: .large)
        #expect(CTFontGetSize(system) == 16.5)
    }

    // MARK: Markdown document layout

    static func document(_ md: String, _ choice: ZeusFontChoice = .pixel) -> AttributedString {
        ZeusMarkdown.style(md, choice: choice, palette: .light, layout: .document)
    }

    @Test func headingsGetLevelsOnlyInTheDocumentLayout() {
        let text = Self.document("# Title\n\n## Part\n\n### Sub\n\nBody")
        let runs = text.runs.map { (String(text[$0.range].characters), $0[ZeusMarkdown.HeadingLevelAttribute.self], $0.font != nil, $0.foregroundColor) }
        let title = try? #require(runs.first { $0.0 == "Title" })
        #expect(title?.1 == 1 && title?.2 == true && title?.3 == ZeusPalette.light.title)
        let part = runs.first { $0.0 == "Part" }
        #expect(part?.1 == 2 && part?.2 == false && part?.3 == ZeusPalette.light.title)
        let sub = runs.first { $0.0 == "Sub" }
        #expect(sub?.1 == 3 && sub?.2 == false)
        let message = ZeusMarkdown.style("# Title", choice: .pixel, palette: .light)
        #expect(message.runs.allSatisfy { $0[ZeusMarkdown.HeadingLevelAttribute.self] == nil && $0.font == nil })
        // SF Mono: H3 is bold text, not gold.
        let system = Self.document("### Sub", .system)
        #expect(system.runs.first?.foregroundColor == nil && system.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    @Test func taskItemsBecomeBoxGlyphs() {
        let text = Self.document("- [ ] Write\n- [x] Read\n- Plain")
        #expect(String(text.characters) == "□ Write\n■ Read\n• Plain")
        let done = text.runs.first { String(text[$0.range].characters) == "■ " }
        #expect(done?.foregroundColor == ZeusPalette.light.title)
        let doneText = text.runs.first { String(text[$0.range].characters).hasPrefix("Read") }
        #expect(doneText?.foregroundColor == ZeusPalette.light.secondaryText)
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: "□■").isEmpty)
    }

    @Test func documentCodeBlocksAndRulesGoWide() {
        let long = String(repeating: "x", count: 50)
        let code = "```\n\(long)\nshort\n```"
        let document = String(Self.document(code).characters).split(separator: "\n")
        #expect(document.allSatisfy { $0.count == long.count + 2 })
        let message = String(ZeusMarkdown.style(code, choice: .pixel, palette: .light).characters).split(separator: "\n")
        #expect(message.last?.count == ZeusMarkdown.codePaddingLimit + 2)
        #expect(String(Self.document("a\n\n---\n\nb").characters).contains(String(repeating: "─", count: 24)))
        #expect(!String(ZeusMarkdown.style("a\n\n---\n\nb", choice: .pixel, palette: .light).characters).contains(String(repeating: "─", count: 13)))
    }

    @Test func documentTablesPadColumnsAndRuleUnderTheHeader() {
        let md = "| Name | Size |\n|---|---|\n| Outline.md | 2 KB |\n| Q3 Planning.key | 12 MB |"
        let lines = String(Self.document(md).characters).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "Name            │ Size")
        #expect(lines[1] == "────────────────┼──────")   // the rule spans the widest cell of each column
        #expect(lines[2] == "Outline.md      │ 2 KB")
        #expect(lines[3] == "Q3 Planning.key │ 12 MB")
        // The message layout is unchanged: no padding, no rule.
        let message = String(ZeusMarkdown.style(md, choice: .pixel, palette: .light).characters).split(separator: "\n")
        #expect(message.count == 3 && message[0] == "Name │ Size")
    }

    @Test func imagesNeverLoadInsideTextAndLocalStandaloneOnesBecomeSegments() {
        let md = "Intro ![a chart](https://example.com/c.png) here.\n\n![Slide](slides/7.png)\n\n![Logo](https://example.com/l.png)\n\nEnd"
        let segments = ZeusMarkdown.documentSegments(md, choice: .pixel, palette: .light)
        #expect(segments.count == 3)
        guard case .text(let first) = segments[0], case .image(let path, let alt) = segments[1], case .text(let last) = segments[2] else {
            Issue.record("unexpected segments \(segments)"); return
        }
        #expect(String(first.characters) == "Intro [image: a chart] here.")
        #expect(path == "slides/7.png" && alt == "Slide")
        #expect(String(last.characters) == "[image: Logo]\n\nEnd")
        #expect(ZeusMarkdown.isRemote("https://x") && ZeusMarkdown.isRemote("//cdn/x.png") && !ZeusMarkdown.isRemote("img/x.png") && !ZeusMarkdown.isRemote("/tmp/x.png"))
        // Inside a fence, an image line is code.
        let fenced = ZeusMarkdown.documentSegments("```\n![x](a.png)\n```", choice: .pixel, palette: .light)
        #expect(fenced.count == 1)
    }

    @Test func documentAndMessageLayoutsAreCachedApart() {
        let md = "# Cached"
        let message = ZeusMarkdown.attributed(md, choice: .pixel, palette: .light)
        let document = ZeusMarkdown.attributed(md, choice: .pixel, palette: .light, layout: .document)
        #expect(message != document)
        #expect(ZeusMarkdown.attributed(md, choice: .pixel, palette: .light, layout: .document, scale: .larger) != document)
    }

    // MARK: Renders

    @Test func viewerChromeRendersInBothSchemesAndFonts() throws {
        ZeusFonts.registerBundled()
        let model = ZeusViewerHeaderModel(title: "Q3 Planning.md", location: "~/Documents/Talks", openTitle: "Open in Keynote",
                                          step: .init(index: 2, count: 3))
        for scheme in [ColorScheme.light, .dark] {
            for choice in ZeusFontChoice.allCases {
                func check(_ view: some View, minHeight: CGFloat, _ what: String) throws {
                    let framed = view.frame(width: 348).environment(\.colorScheme, scheme).environment(\.zeusFontChoice, choice)
                    let image = try #require(ImageRenderer(content: framed).cgImage, Comment(rawValue: what))
                    #expect(CGFloat(image.height) >= minHeight, Comment(rawValue: what))
                }
                try check(ZeusViewerHeader(model, menu: [.init("Copy Path")], onBack: {}, onOpen: {}, onReveal: {}, onExpand: {}),
                          minHeight: ZeusViewerHeader.rowHeight * 2, "header")
                try check(ZeusViewerContextLine(.message("Here's the first draft."), trailing: "Page 3 of 12") {},
                          minHeight: ZeusViewerContextLine.height, "context")
                try check(ZeusViewerStatus(name: "Q3 Planning.key", detail: "Keynote · 1.2 MB", message: ZeusViewerStatus.Copy.unsupported,
                                           actions: [.init("Open in Keynote", style: .primary) {}, .init("Show in Finder") {}]),
                          minHeight: 80, "status")
                try check(ZeusFolderRow(name: "Outline.md", kind: "Markdown", modified: "Yesterday", symbol: "doc.fill") {},
                          minHeight: 22, "row")
                try check(ZeusMarkdownText("# Title\n\nBody with a [link](https://example.com).\n\n- [x] done", layout: .document),
                          minHeight: 40, "markdown")
            }
        }
    }
}
