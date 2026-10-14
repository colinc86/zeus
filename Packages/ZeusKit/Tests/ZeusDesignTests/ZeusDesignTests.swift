import CoreText
import Foundation
import SwiftUI
import Testing
import ZeusProtocol
@testable import ZeusDesign

@Test func bundledFontAndLicenseShip() throws {
    let font = try #require(ZeusFonts.bundledFontURL)
    #expect(FileManager.default.fileExists(atPath: font.path))
    let license = try String(contentsOf: try #require(ZeusFonts.licenseURL), encoding: .utf8)
    #expect(license.contains("SIL Open Font License"))
}

@Test func pixelFontRegistersIdempotently() {
    #expect(ZeusFonts.registerBundled())
    #expect(ZeusFonts.registerBundled())
    #expect(ZeusFonts.isPixelFontAvailable)
}

@Test func everyRoleHasAFontForEveryChoice() {
    for choice in ZeusFontChoice.allCases {
        for role in ZeusTextRole.allCases {
            #expect(role.size(for: choice) >= 10)
        }
    }
    #expect(ZeusFontChoice(rawValue: "pixel") == .pixel)
    #expect(ZeusFontChoice.allCases.map(\.displayName) == ["Pixel", "SF Mono"])
}

@Test func palettesFollowTheScheme() {
    #expect(ZeusPalette.for(.dark) == .dark)
    #expect(ZeusPalette.for(.light) == .light)
    #expect(ZeusPalette.dark != ZeusPalette.light)
}

@Test func progressSegments() {
    #expect(ZeusProgressBar.litSegments(value: 0, count: 10) == 0)
    #expect(ZeusProgressBar.litSegments(value: 0.62, count: 10) == 6)
    #expect(ZeusProgressBar.litSegments(value: 1, count: 10) == 10)
    #expect(ZeusProgressBar.litSegments(value: 1.7, count: 10) == 10)
    #expect(ZeusProgressBar.litSegments(value: -1, count: 10) == 0)
    #expect(ZeusProgressBar.litSegments(value: .nan, count: 10) == 0)
}

@Test func badgeCapsAtNinePlus() {
    #expect(ZeusBadge.text(for: 1) == "1")
    #expect(ZeusBadge.text(for: 9) == "9")
    #expect(ZeusBadge.text(for: 10) == "9+")
    #expect(ZeusBadge.text(for: -2) == "0")
}

@Test func attachmentRowSummaries() {
    let file = Attachment(id: "a", kind: .file, label: "Draft", target: "~/Documents/Q3 Planning.key")
    let folder = Attachment(id: "b", kind: .folder, label: "Out", target: "/tmp/out/")
    let url = Attachment(id: "c", kind: .url, label: "Docs", target: "https://docs.example.com/q3")
    #expect(ZeusAttachmentRow.shortTarget(file) == "Q3 Planning.key")
    #expect(ZeusAttachmentRow.shortTarget(folder) == "out")
    #expect(ZeusAttachmentRow.shortTarget(url) == "docs.example.com")
    #expect(Set(Attachment.Kind.allCases.map(ZeusAttachmentRow.symbol(for:))).count == 3)
}

@Test func pixelRectangleStaysInsideItsBounds() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
    let path = PixelRoundedRectangle().path(in: rect)
    #expect(path.boundingRect == rect)
    #expect(!path.contains(CGPoint(x: 0.5, y: 0.5)))            // corner is cut
    #expect(path.contains(CGPoint(x: 50, y: 20)))
    let tiny = PixelRoundedRectangle().path(in: CGRect(x: 0, y: 0, width: 3, height: 3))
    #expect(tiny.boundingRect.width == 3)                        // degrades to square, no crash
    #expect(PixelRoundedRectangle().inset(by: 60).path(in: rect).isEmpty)
}

@MainActor @Test func galleryRenders() throws {
    ZeusFonts.registerBundled()
    let renderer = ImageRenderer(content: ZeusComponentGallery(snapshot: true))
    let image = try #require(renderer.cgImage)
    #expect(image.width > 900 && image.height > 400)
}

@Test func pixelFontIsDepartureMonoWithoutLigatures() {
    ZeusFonts.registerBundled()
    func glyphCount(_ text: String, _ font: CTFont) -> Int {
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        return CTLineGetGlyphCount(CTLineCreateWithAttributedString(attributed))
    }
    let font = ZeusFonts.pixelCTFont(size: 11)
    #expect(CTFontCopyFamilyName(font) as String == "Departure Mono")
    #expect(glyphCount("first", font) == 5)
    // The confusable pairs that sank Pixelify Sans are distinct glyphs (shapes measured in docs/design/font-candidates.md).
    func outline(_ ch: String) -> CGRect? {
        var u = Array(ch.utf16), g = [CGGlyph](repeating: 0, count: 1)
        guard CTFontGetGlyphsForCharacters(font, &u, &g, 1) else { return nil }
        return CTFontCreatePathForGlyph(font, g[0], nil).map { _ in CGRect(x: Int(g[0]), y: 0, width: 1, height: 1) }
    }
    for (a, b) in [("Z", "2"), ("S", "5"), ("0", "O"), ("8", "B"), ("l", "I")] {
        #expect(outline(a) != nil && outline(a) != outline(b), "\(a)/\(b)")
    }
}

@Test func pixelSizesSitOnTheFontGrid() {
    for role in ZeusTextRole.allCases {
        let size = role.size(for: .pixel)
        #expect(size.truncatingRemainder(dividingBy: ZeusTextRole.pixelGridStep) == 0, "\(role) \(size)")
        #expect(size >= 11)
    }
}

@MainActor @Test func fontOverrideRendersWithItsOwnSizes() throws {
    ZeusFonts.registerBundled()
    let override = ZeusFontOverride(family: ZeusFonts.pixelFamily, sizes: [.title: 33])
    func width(_ o: ZeusFontOverride?) throws -> Int {
        let view = Text("Zeus").zeusFont(.title).environment(\.zeusFontOverride, o).fixedSize()
        return try #require(ImageRenderer(content: view).cgImage).width
    }
    #expect(try width(override) > width(nil))     // 33 pt title vs the default 16.5 pt
}

@Test func strongIsAccentInPixelAndBoldInSystem() {
    let md = "Ship **v0.3** with `zeus-mcp` now"
    let pixel = ZeusMarkdown.attributed(md, choice: .pixel, palette: .dark)
    let system = ZeusMarkdown.attributed(md, choice: .system, palette: .dark)
    #expect(String(pixel.characters) == "Ship v0.3 with zeus-mcp now")
    func run(_ text: AttributedString, _ substring: String) -> AttributedString.Runs.Run? {
        text.runs.first { String(text[$0.range].characters) == substring }
    }
    // Pixel: strong → gold, keeping its strong intent (so .system-style bold still applies where a bold face exists).
    #expect(run(pixel, "v0.3")?.foregroundColor == ZeusPalette.dark.title)
    #expect(run(pixel, "v0.3")?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    // System: no recolor; real bold comes from the intent.
    #expect(run(system, "v0.3")?.foregroundColor == nil)
    // Code: tinted in both.
    #expect(run(pixel, "zeus-mcp")?.backgroundColor == ZeusPalette.dark.secondaryFill)
    #expect(run(system, "zeus-mcp")?.backgroundColor == ZeusPalette.dark.secondaryFill)
    // Plain runs untouched.
    #expect(run(pixel, "Ship ")?.foregroundColor == nil && run(pixel, "Ship ")?.backgroundColor == nil)
    // Unparseable markdown falls back to plain text.
    #expect(String(ZeusMarkdown.attributed("plain", choice: .pixel, palette: .light).characters) == "plain")
}

@MainActor @Test func warningMarkerRendersAtBadgeSize() throws {
    ZeusFonts.registerBundled()
    let marker = try #require(ImageRenderer(content: ZeusWarningMarker()).cgImage)
    let badge = try #require(ImageRenderer(content: ZeusBadge(count: 3)).cgImage)
    #expect(marker.height == badge.height)
}
