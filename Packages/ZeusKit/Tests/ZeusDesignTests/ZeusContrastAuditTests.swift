import SwiftUI
import Testing
@testable import ZeusDesign

/// WCAG 2.2 contrast for every text/background pair the Zeus chrome draws.
/// Opacity modifiers are composited the way the views apply them, in gamma-encoded sRGB.
struct ZeusContrastAuditTests {
    struct RGB { var r, g, b: Double }

    static func rgb(_ color: Color) -> RGB {
        let c = color.resolve(in: EnvironmentValues())
        func encode(_ v: Float) -> Double {
            let x = Double(v)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return RGB(r: encode(c.linearRed), g: encode(c.linearGreen), b: encode(c.linearBlue))
    }

    /// `top` at `alpha` over `bottom`.
    static func over(_ top: RGB, _ alpha: Double, _ bottom: RGB) -> RGB {
        RGB(r: top.r * alpha + bottom.r * (1 - alpha), g: top.g * alpha + bottom.g * (1 - alpha), b: top.b * alpha + bottom.b * (1 - alpha))
    }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    struct Pair: CustomStringConvertible {
        let name: String
        let fg: RGB
        let bg: RGB
        let minimum: Double  // 4.5 for text, 3 for non-text UI (WCAG 1.4.11)
        var value: Double { ZeusContrastAuditTests.ratio(fg, bg) }
        var description: String { "\(name): \(String(format: "%.2f", value)):1 (needs \(minimum))" }
    }

    static let palettes: [String: ZeusPalette] = ["light": .light, "dark": .dark, "light-hc": .lightHighContrast, "dark-hc": .darkHighContrast]

    /// Text needs AA (4.5:1) normally and AAA (7:1) under Increase Contrast; controls and indicators need 3:1.
    static func pairs(_ p: ZeusPalette, _ scheme: String) -> [Pair] {
        let c = rgb
        let text = scheme.hasSuffix("hc") ? 7.0 : 4.5
        let desktop = scheme.hasPrefix("light") ? RGB(r: 0.79, g: 0.83, b: 0.88) : RGB(r: 0.18, g: 0.2, b: 0.25)
        let panel = over(c(p.panel), 0.97, desktop)
        let bubble = c(p.agentBubble)
        let attachment = over(c(p.field), 0.55, bubble)
        let hint = ZeusOptionButtons.shortcutOpacity
        return [
            Pair(name: "body text on agent bubble", fg: c(p.text), bg: bubble, minimum: text),
            Pair(name: "user text on user bubble", fg: c(p.onUserBubble), bg: c(p.userBubble), minimum: text),
            Pair(name: "bubble title / bold run on agent bubble", fg: c(p.title), bg: bubble, minimum: text),
            Pair(name: "timestamp (secondary) on agent bubble", fg: c(p.secondaryText), bg: bubble, minimum: text),
            Pair(name: "caption/session label/divider (secondary) on panel", fg: c(p.secondaryText), bg: panel, minimum: text),
            Pair(name: "empty-state title on panel", fg: c(p.title), bg: panel, minimum: text),
            Pair(name: "'Not sent' / error caption (destructive) on panel", fg: c(p.destructive), bg: panel, minimum: text),
            Pair(name: "attachment error (destructive) on agent bubble", fg: c(p.destructive), bg: bubble, minimum: text),
            Pair(name: "primary button label", fg: c(p.onAccent), bg: c(p.accent), minimum: text),
            Pair(name: "secondary button label", fg: c(p.onSecondary), bg: c(p.secondaryFill), minimum: text),
            Pair(name: "destructive button label", fg: c(p.onDestructive), bg: c(p.destructive), minimum: text),
            Pair(name: "⌘n hint on primary button", fg: over(c(p.onAccent), hint, c(p.accent)), bg: c(p.accent), minimum: 4.5),
            Pair(name: "⌘n hint on secondary button", fg: over(c(p.onSecondary), hint, c(p.secondaryFill)), bg: c(p.secondaryFill), minimum: 4.5),
            Pair(name: "badge count (dark badge on the desktop)", fg: c(ZeusPalette.dark.onBadge), bg: c(ZeusPalette.dark.badge), minimum: 4.5),
            Pair(name: "composer placeholder on field", fg: c(p.secondaryText), bg: c(p.field), minimum: text),
            Pair(name: "attachment subtitle on attachment row", fg: c(p.secondaryText), bg: attachment, minimum: text),
            // Muted (dismissed/expired) bubbles: a panel-colored fill with mutedText for title, body and time.
            Pair(name: "muted (dismissed) text", fg: c(p.mutedText), bg: panel, minimum: text),
            Pair(name: "muted (dismissed) bold run", fg: c(p.title), bg: panel, minimum: text),
            Pair(name: "muted bubble outline vs panel", fg: c(p.fieldBorder), bg: panel, minimum: scheme.hasSuffix("hc") ? 3 : 1.5),
            Pair(name: "ZeusPeekBubble ✕ close at rest", fg: c(p.secondaryText), bg: panel, minimum: 3),
            Pair(name: "progress fill vs track", fg: c(p.fill), bg: c(p.track), minimum: 3),
            Pair(name: "session dot 1 on panel", fg: c(p.sessionColors[0]), bg: panel, minimum: 3),
            Pair(name: "session dot 2 on panel", fg: c(p.sessionColors[1]), bg: panel, minimum: 3),
            Pair(name: "session dot 3 on panel", fg: c(p.sessionColors[2]), bg: panel, minimum: 3),
            Pair(name: "session dot 4 on panel", fg: c(p.sessionColors[3]), bg: panel, minimum: 3),
            Pair(name: "composer focus ring vs panel", fg: c(p.focusRing), bg: panel, minimum: 3),
            Pair(name: "running indicator (positive) on panel", fg: c(p.positive), bg: panel, minimum: 3),
            // App-side controls and full-strength sending text (F8 and F9/F10 follow-ups).
            Pair(name: "app: sending bubble user text", fg: c(p.onUserBubble), bg: c(p.userBubble), minimum: text),
            Pair(name: "app: answered peek option", fg: c(p.onAccent), bg: c(p.accent), minimum: 4.5),
            Pair(name: "app: PeekContent close at rest", fg: c(p.secondaryText), bg: panel, minimum: 3),
        ]
    }

    @Test(arguments: ["light", "dark", "light-hc", "dark-hc"])
    func contrastMeetsWCAG(_ scheme: String) throws {
        let palette = try #require(Self.palettes[scheme])
        for pair in Self.pairs(palette, scheme) {
            print("[contrast \(scheme)] \(pair)")
            #expect(pair.value >= pair.minimum, "\(pair)")
        }
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
