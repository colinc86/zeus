import Foundation
import Testing
@testable import ZeusDesign

/// Q2 DES-4: every UI string is drawable in the pixel font, so nothing falls back to a vector glyph.
struct ZeusGlyphCoverageTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// (file, line, missing characters) for each string literal in `directory` with a glyph the font lacks.
    static func missing(in directory: String) throws -> [(String, Int, [Character])] {
        let root = repo.appendingPathComponent(directory)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.contains("/Tests/") } ?? []
        var found: [(String, Int, [Character])] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                for literal in pixelFontLiterals(in: line) {
                    let gaps = ZeusFonts.pixelFontMissingGlyphs(in: literal)
                    if !gaps.isEmpty { found.append((file.lastPathComponent, number + 1, gaps)) }
                }
            }
        }
        return found
    }

    /// Native string tooltips use the system font. Only omit that argument, not other text on the same line.
    static func pixelFontLiterals(in line: String) -> [String] {
        line.matches(of: /"((?:[^"\\]|\\.)*)"/).compactMap { match in
            let prefix = line[..<match.range.lowerBound].trimmingCharacters(in: .whitespaces)
            return prefix.hasSuffix(".help(") ? nil : String(match.output.1)
        }
    }

    @Test func nativeTooltipsDoNotExemptRenderedTextOnTheSameLine() {
        #expect(Self.pixelFontLiterals(in: #".help("Skip (⇧⌘J)")"#).isEmpty)
        #expect(Self.pixelFontLiterals(in: #"Text("✓").help("⇧")"#) == ["✓"])
        #expect(Self.pixelFontLiterals(in: #".help("⇧").overlay { Text("✓") }"#) == ["✓"])
        #expect(Self.pixelFontLiterals(in: #"Text("⇧")"#) == ["⇧"])
    }

    @Test func glyphsCoverEverySymbolTheyReplace() {
        for symbol in ZeusGlyph.Symbol.allCases {
            #expect(symbol.rows.count == 7, "\(symbol) must be the font's 7-px cap height")
            #expect(Set(symbol.rows.map(\.count)).count == 1, "\(symbol) rows must be equal width")
            #expect(symbol.rows.joined().contains("#"))
        }
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: "✓✕↩◀▶●") == ["✓", "✕", "↩", "◀", "▶", "●"])
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: "× · … ⌘ ⌥ ↓ ↑ → • ▌ │ ─").isEmpty)
    }

    @Test func zeusDesignStringsUseOnlyPixelFontGlyphs() throws {
        let gaps = try Self.missing(in: "Packages/ZeusKit/Sources/ZeusDesign")
        #expect(gaps.isEmpty, "\(gaps)")
    }

    /// The DMG window's text is set in the pixel font too (F11, Q2 DES-20), and the footer says where Settings lives.
    @Test func dmgTextUsesOnlyPixelFontGlyphsAndPointsToTheMenuBar() throws {
        let gaps = try Self.missing(in: "Packages/ZeusKit/Sources/zeus-sprites").filter { $0.0 == "DMGArt.swift" }
        #expect(gaps.isEmpty, "\(gaps)")
        let source = try String(contentsOf: Self.repo.appendingPathComponent("Packages/ZeusKit/Sources/zeus-sprites/DMGArt.swift"), encoding: .utf8)
        #expect(source.contains("\"Then open Zeus: click \"") && source.contains("\" in the menu bar, then Settings → Assistant.\""))
        #expect(!source.contains("choose your agent in Settings."), "the old footer assumed a findable Settings")
    }

    /// UI literals only: terminal prompt detection and wire payloads aren't rendered in the pixel font.
    @Test func appStringsUseOnlyPixelFontGlyphs() throws {
        let gaps = try ["Zeus/App", "Zeus/Avatar", "Zeus/Cards", "Zeus/Settings"].flatMap { try Self.missing(in: $0) }
        #expect(gaps.isEmpty, "\(gaps)")
    }
}
