import SwiftUI

/// Zeus's retro dialog-box look: a framed panel with stepped "pixel" corners, a gold accent,
/// and a pixel font. Everything is measured in UI pixels of `ZeusTheme.pixel` points so the
/// chrome stays crisp next to the sprite.
public enum ZeusTheme {
    /// One UI pixel, in points. Borders, notched corners and the dialog tail are multiples of it.
    public static let pixel: CGFloat = 2

    /// The frame thickness: 1 px dark outline + 1 px light frame, in points.
    public static let borderWidth: CGFloat = pixel * 2

    /// Corner style: corners are cut in `cornerSteps` stair steps of one UI pixel.
    public static let cornerSteps = 2

    /// Spacing scale, in points.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    /// Recommended card width range, in points (CARDS.md).
    public static let cardMinWidth: CGFloat = 260
    public static let cardMaxWidth: CGFloat = 360

    /// Conversation panel (CONVERSATION.md §6).
    public enum Conversation {
        /// Panel width, including the dialog frame.
        public static let panelWidth: CGFloat = 380
        /// Thread height limits; the panel never exceeds `maxHeightFraction` of the screen's visible height.
        public static let minThreadHeight: CGFloat = 160
        public static let maxThreadHeight: CGFloat = 520
        public static let maxHeightFraction: CGFloat = 0.7
        /// Bubble width limits.
        public static let agentBubbleMaxWidth: CGFloat = 316
        public static let userBubbleMaxWidth: CGFloat = 272
        /// Vertical gap between bubbles; consecutive bubbles from the same speaker use `groupedSpacing`.
        public static let spacing: CGFloat = 10
        public static let groupedSpacing: CGFloat = 4
        /// Composer field height, in lines.
        public static let composerLines = 1...6
    }
}

/// The colors of one appearance. In a view, read `@Environment(\.zeusPalette)`: it follows the color scheme
/// and Increase Contrast. Elsewhere, pick one with `ZeusPalette.for(_:contrast:)`.
public struct ZeusPalette: Sendable, Hashable {
    /// Outermost 1-px outline of panels, buttons and fields.
    public var outline: Color
    /// The light frame just inside the outline.
    public var frame: Color
    /// Panel background.
    public var panel: Color
    /// Primary text.
    public var text: Color
    /// Secondary text: metadata, placeholders, paths.
    public var secondaryText: Color
    /// Titles and the pager.
    public var title: Color
    /// Primary action fill (gold) and its label color.
    public var accent: Color
    public var onAccent: Color
    /// Secondary action fill and label.
    public var secondaryFill: Color
    public var onSecondary: Color
    /// Destructive action fill and label.
    public var destructive: Color
    public var onDestructive: Color
    /// Text field background and its inner border.
    public var field: Color
    public var fieldBorder: Color
    /// Progress bar track and fill.
    public var track: Color
    public var fill: Color
    /// Count badge.
    public var badge: Color
    public var onBadge: Color
    /// Hard drop shadow under panels (offset, not blurred).
    public var shadow: Color
    /// Conversation bubbles: the agent's (framed, left) and the user's (filled, right).
    public var agentBubble: Color
    public var userBubble: Color
    public var onUserBubble: Color
    /// Session label dots, chosen by a stable hash of the session key (CONVERSATION.md §3).
    public var sessionColors: [Color]
    /// The keyboard-focus ring around fields (at least 3:1 against the panel).
    public var focusRing: Color
    /// "Running" and other healthy states (at least 3:1 against the panel; never the only cue).
    public var positive: Color

    /// The dark appearance: a midnight dialog box with a pale frame.
    public static let dark = ZeusPalette(
        outline: Color(hex: 0x0D0B16), frame: Color(hex: 0xEFEAFF), panel: Color(hex: 0x1E1A2E),
        text: Color(hex: 0xF4F1FF), secondaryText: Color(hex: 0xA9A3C7), title: Color(hex: 0xF6C544),
        accent: Color(hex: 0xF6C544), onAccent: Color(hex: 0x2A1D05),
        secondaryFill: Color(hex: 0x3A3354), onSecondary: Color(hex: 0xF4F1FF),
        destructive: Color(hex: 0xF06A7E), onDestructive: Color(hex: 0x1A0710),
        field: Color(hex: 0x120F1D), fieldBorder: Color(hex: 0x5B5380),
        track: Color(hex: 0x2C2640), fill: Color(hex: 0x7AD7FF),
        badge: Color(hex: 0xC8364D), onBadge: Color(hex: 0xFFFFFF),
        shadow: Color(hex: 0x000000, opacity: 0.35),
        agentBubble: Color(hex: 0x29243D), userBubble: Color(hex: 0x2F4E6E), onUserBubble: Color(hex: 0xF4F1FF),
        sessionColors: [Color(hex: 0x7AD7FF), Color(hex: 0xF6C544), Color(hex: 0x8DE08A), Color(hex: 0xFF9FD0)],
        focusRing: Color(hex: 0xF6C544),
        positive: Color(hex: 0x8DE08A)
    )

    /// The light appearance: a parchment dialog box with an ink frame.
    public static let light = ZeusPalette(
        outline: Color(hex: 0x2A2140), frame: Color(hex: 0xC9BFA3), panel: Color(hex: 0xFBF7EA),
        text: Color(hex: 0x2A2140), secondaryText: Color(hex: 0x6E6488), title: Color(hex: 0x9A6408),
        accent: Color(hex: 0xF6C544), onAccent: Color(hex: 0x2A1D05),
        secondaryFill: Color(hex: 0xEDE5CF), onSecondary: Color(hex: 0x2A2140),
        destructive: Color(hex: 0xC8364D), onDestructive: Color(hex: 0xFFFFFF),
        field: Color(hex: 0xFFFFFF), fieldBorder: Color(hex: 0xB8AD8F),
        track: Color(hex: 0xE9E1C9), fill: Color(hex: 0x2B74B8),
        badge: Color(hex: 0xC8364D), onBadge: Color(hex: 0xFFFFFF),
        shadow: Color(hex: 0x2A2140, opacity: 0.25),
        agentBubble: Color(hex: 0xFFFFFF), userBubble: Color(hex: 0xDCEBFA), onUserBubble: Color(hex: 0x2A2140),
        sessionColors: [Color(hex: 0x2F7FC8), Color(hex: 0xB07A10), Color(hex: 0x3E9A4A), Color(hex: 0xC0508A)],
        focusRing: Color(hex: 0xA87000),
        positive: Color(hex: 0x2E7D3A)
    )

    /// Increase Contrast, dark: full-strength frame and text, darker fills behind light labels.
    public static let darkHighContrast = ZeusPalette(
        outline: Color(hex: 0x000000), frame: Color(hex: 0xFFFFFF), panel: Color(hex: 0x141020),
        text: Color(hex: 0xFFFFFF), secondaryText: Color(hex: 0xD6D1F0), title: Color(hex: 0xFFD966),
        accent: Color(hex: 0xFFD966), onAccent: Color(hex: 0x1A1000),
        secondaryFill: Color(hex: 0x3A3354), onSecondary: Color(hex: 0xFFFFFF),
        destructive: Color(hex: 0xFF8A9A), onDestructive: Color(hex: 0x1A0710),
        field: Color(hex: 0x0A0812), fieldBorder: Color(hex: 0xB0A8DC),
        track: Color(hex: 0x2C2640), fill: Color(hex: 0x9AE4FF),
        badge: Color(hex: 0xA82238), onBadge: Color(hex: 0xFFFFFF),
        shadow: Color(hex: 0x000000, opacity: 0.5),
        agentBubble: Color(hex: 0x221D33), userBubble: Color(hex: 0x1F3A57), onUserBubble: Color(hex: 0xFFFFFF),
        sessionColors: [Color(hex: 0x9AE4FF), Color(hex: 0xFFD966), Color(hex: 0xA6F0A2), Color(hex: 0xFFB8DD)],
        focusRing: Color(hex: 0xFFD966),
        positive: Color(hex: 0xA6F0A2)
    )

    /// Increase Contrast, light: ink outline and frame, darker secondary text and accents.
    public static let lightHighContrast = ZeusPalette(
        outline: Color(hex: 0x000000), frame: Color(hex: 0x4A4060), panel: Color(hex: 0xFFFDF5),
        text: Color(hex: 0x14101F), secondaryText: Color(hex: 0x433A58), title: Color(hex: 0x6E4500),
        accent: Color(hex: 0xF6C544), onAccent: Color(hex: 0x1A1000),
        secondaryFill: Color(hex: 0xE4DAC0), onSecondary: Color(hex: 0x14101F),
        destructive: Color(hex: 0xA51F35), onDestructive: Color(hex: 0xFFFFFF),
        field: Color(hex: 0xFFFFFF), fieldBorder: Color(hex: 0x4A4060),
        track: Color(hex: 0xD8CFB4), fill: Color(hex: 0x1C5A96),
        badge: Color(hex: 0xA82238), onBadge: Color(hex: 0xFFFFFF),
        shadow: Color(hex: 0x14101F, opacity: 0.4),
        agentBubble: Color(hex: 0xFFFFFF), userBubble: Color(hex: 0xD3E5F8), onUserBubble: Color(hex: 0x14101F),
        sessionColors: [Color(hex: 0x1C5A96), Color(hex: 0x7A5200), Color(hex: 0x24652F), Color(hex: 0x8E2F63)],
        focusRing: Color(hex: 0x6E4500),
        positive: Color(hex: 0x1D5E28)
    )

    /// The palette for a color scheme and contrast (Increase Contrast picks the high-contrast palettes).
    public static func `for`(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> ZeusPalette {
        switch (scheme, contrast) {
        case (.dark, .increased): .darkHighContrast
        case (.dark, _): .dark
        case (_, .increased): .lightHighContrast
        default: .light
        }
    }

    /// All built-in palettes, in a stable order.
    public static let builtIn: [ZeusPalette] = [.dark, .light, .darkHighContrast, .lightHighContrast]

    /// Text in a dismissed or expired bubble: the secondary color, never faded with opacity (WCAG AA).
    public var mutedText: Color { secondaryText }
}

extension Color {
    /// A color from a 0xRRGGBB literal, in sRGB.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension EnvironmentValues {
    /// The user's font setting. Set it once near the root: `.environment(\.zeusFontChoice, choice)`.
    @Entry public var zeusFontChoice: ZeusFontChoice = .pixel

    /// Whether the surface showing this view is visible (not hidden, occluded, locked or asleep).
    /// When `false`, ZeusDesign clocks stop: activity dots and indeterminate progress hold a static
    /// frame, and the peek typewriter shows the full text. The app sets it per surface (P8 #2/#4).
    @Entry public var zeusAnimationsActive: Bool = true

    /// The Zeus palette for this view: the selected theme (`\.zeusTheme`), the color scheme and Increase Contrast.
    /// Read it with `@Environment(\.zeusPalette) private var palette` instead of `ZeusPalette.for(colorScheme)`.
    public var zeusPalette: ZeusPalette { zeusTheme.palette(for: colorScheme, contrast: colorSchemeContrast) }

    /// Set by `ZeusBubble` for a dismissed or expired card, so its header and text recede without opacity.
    @Entry public var zeusMuted: Bool = false
}

/// Reads the palette for the current color scheme.
struct ZeusPaletteReader<Content: View>: View {
    @Environment(\.zeusPalette) private var palette
    let content: (ZeusPalette) -> Content

    var body: some View { content(palette) }
}
