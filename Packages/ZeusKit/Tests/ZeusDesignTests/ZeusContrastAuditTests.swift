import SwiftUI
import Testing
@testable import ZeusDesign

/// WCAG 2.2 contrast for every text/background pair the Zeus chrome draws.
/// Opacity modifiers are composited the way the views apply them, in gamma-encoded sRGB.
struct ZeusContrastAuditTests {
    typealias RGB = ZeusContrast.RGB
    static func rgb(_ color: Color) -> RGB { ZeusContrast.rgb(color) }
    static func ratio(_ a: RGB, _ b: RGB) -> Double { ZeusContrast.ratio(a, b) }

    static let palettes: [String: ZeusPalette] = ["light": .light, "dark": .dark, "light-hc": .lightHighContrast, "dark-hc": .darkHighContrast]

    /// Text needs AA (4.5:1) normally and AAA (7:1) under Increase Contrast; controls and indicators need 3:1.
    /// The pair list lives in `ZeusContrast`, so Settings flags an imported theme with exactly these rules.
    static func pairs(_ p: ZeusPalette, _ scheme: String) -> [ZeusContrast.Pair] {
        ZeusContrast.pairs(p, dark: scheme.hasPrefix("dark"), highContrast: scheme.hasSuffix("hc"))
    }

    @Test(arguments: ["light", "dark", "light-hc", "dark-hc"])
    func contrastMeetsWCAG(_ scheme: String) throws {
        let palette = try #require(Self.palettes[scheme])
        for pair in Self.pairs(palette, scheme) {
            print("[contrast \(scheme)] \(pair)")
            #expect(pair.value >= pair.minimum, "\(pair)")
        }
        #expect(Self.pairs(palette, scheme).count >= 30)
    }
}

extension ZeusContrastAuditTests {
    /// Q2 DES-5: Increase Contrast reaches every view that reads `\.zeusPalette`.
    @Test func increaseContrastPicksTheHighContrastPalettes() {
        var env = EnvironmentValues()
        for (scheme, standard, increased) in [(ColorScheme.light, ZeusPalette.light, ZeusPalette.lightHighContrast),
                                              (.dark, .dark, .darkHighContrast)] {
            env.colorScheme = scheme
            env._colorSchemeContrast = .standard
            #expect(env.zeusPalette == standard)
            env._colorSchemeContrast = .increased
            #expect(env.zeusPalette == increased)
        }
        #expect(ZeusPalette.builtIn.count == Set(ZeusPalette.builtIn.map { "\($0.panel)\($0.text)" }).count)
    }

    /// Markdown cached per palette: a high-contrast palette never reuses the standard one's colors.
    @Test func markdownCacheSeparatesContrastPalettes() {
        let standard = ZeusMarkdown.attributed("a **b**", choice: .pixel, palette: .light)
        let increased = ZeusMarkdown.attributed("a **b**", choice: .pixel, palette: .lightHighContrast)
        func bold(_ t: AttributedString) -> Color? { t.runs.first { String(t[$0.range].characters) == "b" }?.foregroundColor }
        #expect(bold(standard) == ZeusPalette.light.title)
        #expect(bold(increased) == ZeusPalette.lightHighContrast.title)
    }
}
