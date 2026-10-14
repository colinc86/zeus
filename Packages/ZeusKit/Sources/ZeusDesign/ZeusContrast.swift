import SwiftUI

/// WCAG 2.2 contrast for every text/background pair the Zeus chrome draws. `ZeusContrastAuditTests` holds every
/// bundled palette to it, and Settings › Appearance tags an imported theme that misses it as "Low contrast".
/// Opacity is composited the way the views apply it, in gamma-encoded sRGB.
public enum ZeusContrast {
    /// A gamma-encoded sRGB color, 0…1.
    public struct RGB: Sendable, Equatable {
        public var r, g, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }

    /// One pair the views draw, and how much contrast it needs.
    public struct Pair: Sendable, CustomStringConvertible {
        public let name: String
        public let fg: RGB
        public let bg: RGB
        /// 4.5 for text (7 under Increase Contrast), 3 for controls and indicators (WCAG 1.4.11).
        public let minimum: Double
        public var value: Double { ZeusContrast.ratio(fg, bg) }
        public var passes: Bool { value >= minimum }
        public var description: String { "\(name): \(String(format: "%.2f", value)):1 (needs \(minimum))" }
        /// Plain words for Settings, e.g. "body text on the assistant's bubbles is 3.1:1; it needs 4.5:1".
        public var plain: String { "\(name) is \(String(format: "%.1f", value)):1; it needs \(String(format: "%g", minimum)):1" }
    }

    public static func rgb(_ color: Color) -> RGB {
        let c = color.resolve(in: EnvironmentValues())
        func encode(_ v: Float) -> Double {
            let x = Double(v)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return RGB(r: encode(c.linearRed), g: encode(c.linearGreen), b: encode(c.linearBlue))
    }

    /// `top` at `alpha` over `bottom`.
    public static func over(_ top: RGB, _ alpha: Double, _ bottom: RGB) -> RGB {
        RGB(r: top.r * alpha + bottom.r * (1 - alpha), g: top.g * alpha + bottom.g * (1 - alpha), b: top.b * alpha + bottom.b * (1 - alpha))
    }

    public static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Every pair for `p`. `dark` picks the desktop the panel sits on; `highContrast` raises text to AAA (7:1).
    public static func pairs(_ p: ZeusPalette, dark: Bool, highContrast: Bool) -> [Pair] {
        let c = rgb
        let text = highContrast ? 7.0 : 4.5
        let desktop = dark ? RGB(r: 0.18, g: 0.2, b: 0.25) : RGB(r: 0.79, g: 0.83, b: 0.88)
        let panel = over(c(p.panel), 0.97, desktop)
        let bubble = c(p.agentBubble)
        let attachment = over(c(p.field), 0.55, bubble)
        let hint = ZeusOptionButtons.shortcutOpacity
        var list = [
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
            Pair(name: "muted bubble outline vs panel", fg: c(p.fieldBorder), bg: panel, minimum: highContrast ? 3 : 1.5),
            Pair(name: "ZeusPeekBubble close button at rest", fg: c(p.secondaryText), bg: panel, minimum: 3),
            Pair(name: "progress fill vs track", fg: c(p.fill), bg: c(p.track), minimum: 3),
        ]
        for (i, color) in p.sessionColors.enumerated() {
            list.append(Pair(name: "session dot \(i + 1) on panel", fg: c(color), bg: panel, minimum: 3))
        }
        list += [
            Pair(name: "composer focus ring vs panel", fg: c(p.focusRing), bg: panel, minimum: 3),
            Pair(name: "running indicator (positive) on panel", fg: c(p.positive), bg: panel, minimum: 3),
            // App-side controls and full-strength sending text (F8 and F9/F10 follow-ups).
            Pair(name: "app: sending bubble user text", fg: c(p.onUserBubble), bg: c(p.userBubble), minimum: text),
            Pair(name: "app: answered peek option", fg: c(p.onAccent), bg: c(p.accent), minimum: 4.5),
            Pair(name: "app: PeekContent close at rest", fg: c(p.secondaryText), bg: panel, minimum: 3),
        ]
        list += newSurfacePairs(p, dark: dark, highContrast: highContrast)
        return list
    }

    /// The 0.1.8 surfaces (D18): message links, the status strip, quiet thread lines and Settings text, each by name.
    public static func newSurfacePairs(_ p: ZeusPalette, dark: Bool, highContrast: Bool) -> [Pair] {
        let c = rgb
        let text = highContrast ? 7.0 : 4.5
        let desktop = dark ? RGB(r: 0.18, g: 0.2, b: 0.25) : RGB(r: 0.79, g: 0.83, b: 0.88)
        let panel = over(c(p.panel), 0.97, desktop)
        let user = p.userBubbleText
        // Settings draws palette text on the system window background of the theme's own appearance.
        let window = dark ? settingsWindowDark : settingsWindowLight
        return [
            Pair(name: "link on agent bubble", fg: c(p.link), bg: c(p.agentBubble), minimum: text),
            Pair(name: "link in a dismissed bubble (panel)", fg: c(p.link), bg: panel, minimum: text),
            Pair(name: "link on user bubble", fg: c(user.link), bg: c(p.userBubble), minimum: text),
            Pair(name: "bold run on user bubble", fg: c(user.title), bg: c(p.userBubble), minimum: text),
            Pair(name: "strip: sentence (text) on panel", fg: c(p.text), bg: panel, minimum: text),
            Pair(name: "strip: ?/! glyph and link words (title) on panel", fg: c(p.title), bg: panel, minimum: text),
            Pair(name: "strip: Idle / Quiet until (secondary) on panel", fg: c(p.secondaryText), bg: panel, minimum: text),
            Pair(name: "strip: icon at rest (secondary) on panel", fg: c(p.secondaryText), bg: panel, minimum: 3),
            Pair(name: "strip: icon on hover or focus (title) on panel", fg: c(p.title), bg: panel, minimum: 3),
            Pair(name: "strip: divider rule on panel", fg: composite(p.divider, over: panel), bg: panel, minimum: 3),
            Pair(name: "quiet line: summary (secondary) on panel", fg: c(p.secondaryText), bg: panel, minimum: text),
            Pair(name: "quiet line: Undo / View (title) on panel", fg: c(p.title), bg: panel, minimum: text),
            Pair(name: "quiet line: Skipped (secondary) on panel", fg: c(p.secondaryText), bg: panel, minimum: text),
            Pair(name: "Settings: body and slider values (text) on window", fg: c(p.text), bg: window, minimum: text),
            Pair(name: "Settings: captions (secondary) on window", fg: c(p.secondaryText), bg: window, minimum: text),
            Pair(name: "Settings: section titles (title) on window", fg: c(p.title), bg: window, minimum: text),
            Pair(name: "Settings: errors (destructive) on window", fg: c(p.destructive), bg: window, minimum: text),
        ]
    }

    /// macOS's window background, light and dark, behind Settings.
    public static let settingsWindowLight = RGB(r: 0.925, g: 0.925, b: 0.925)
    public static let settingsWindowDark = RGB(r: 0.196, g: 0.196, b: 0.196)

    /// A color with its own opacity, composited over `bottom`.
    public static func composite(_ color: Color, over bottom: RGB) -> RGB {
        over(rgb(color), Double(color.resolve(in: EnvironmentValues()).opacity), bottom)
    }

    /// The pairs that miss their minimum.
    public static func failures(_ p: ZeusPalette, dark: Bool, highContrast: Bool) -> [Pair] {
        pairs(p, dark: dark, highContrast: highContrast).filter { !$0.passes }
    }
}
