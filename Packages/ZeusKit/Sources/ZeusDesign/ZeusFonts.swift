import CoreText
import Foundation
import SwiftUI

/// The user's font setting.
public enum ZeusFontChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The bundled pixel font, Departure Mono (SIL OFL 1.1; license in `Fonts/OFL.txt`). The default.
    case pixel
    /// SF Mono.
    case system

    public var id: String { rawValue }

    /// A label for Settings.
    public var displayName: String {
        switch self {
        case .pixel: "Pixel"
        case .system: "SF Mono"
        }
    }
}

/// Conversation text-size preset. Pixel sizes stay on the font grid; desktop badges do not scale.
public enum ZeusFontScale: String, Codable, Sendable, CaseIterable, Identifiable {
    case small, `default`, large, larger
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .small: "Small"; case .default: "Default"; case .large: "Large"; case .larger: "Larger" }
    }
    public var accessibilityLabel: String { displayName + " text" }
}

/// Where a piece of text sits in the hierarchy.
public enum ZeusTextRole: Sendable, Hashable, CaseIterable {
    case title, body, caption, button, badge

    /// Point size per font. Departure Mono is drawn on an 11 px/em grid, so it's only crisp at multiples of
    /// 5.5 pt (one font pixel = whole device pixels on 2× displays): 11 for text, 16.5 for titles.
    /// Its x-height at 11 pt matches the old 15 pt body; hierarchy comes from size and color (one weight).
    func size(for choice: ZeusFontChoice, scale: ZeusFontScale = .default) -> CGFloat {
        let index = switch scale { case .small: 0; case .default: 1; case .large: 2; case .larger: 3 }
        let sizes: [CGFloat] = switch (self, choice) {
        case (.title, .pixel): [11, 16.5, 22, 22]
        case (.body, .pixel), (.button, .pixel): [11, 11, 16.5, 16.5]
        case (.caption, .pixel): [11, 11, 11, 16.5]
        case (.badge, .pixel): [11, 11, 11, 11]
        case (.title, .system): [12, 14, 16.5, 19]
        case (.body, .system): [10.5, 12.5, 15, 17]
        case (.caption, .system): [9.5, 11, 13, 15]
        case (.button, .system): [10, 12, 14, 16.5]
        case (.badge, .system): [10, 10, 10, 10]
        }
        return sizes[index]
    }

    /// The pixel font's grid step: pixel sizes must be multiples of this to render crisp on 2× displays.
    static let pixelGridStep: CGFloat = 5.5

    var weight: Font.Weight {
        switch self {
        case .title, .button, .badge: .semibold
        case .body, .caption: .regular
        }
    }
}

/// Font registration and lookup.
public enum ZeusFonts {
    /// The family name of the bundled pixel font.
    public static let pixelFamily = "Departure Mono"

    /// The bundled font file.
    public static var bundledFontURL: URL? {
        Bundle.module.url(forResource: "DepartureMono-Regular", withExtension: "otf", subdirectory: "Fonts")
    }

    /// The bundled font's license text (SIL Open Font License 1.1). Show it in an About/Acknowledgements screen.
    public static var licenseURL: URL? {
        Bundle.module.url(forResource: "OFL", withExtension: "txt", subdirectory: "Fonts")
    }

    /// Registers the bundled pixel font for this process. Call once at launch; calling again is harmless.
    /// - Returns: whether the font is available afterwards.
    @discardableResult
    public static func registerBundled() -> Bool {
        guard let url = bundledFontURL else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
        return code == CTFontManagerError.alreadyRegistered.rawValue || isPixelFontAvailable
    }

    /// Whether the pixel font can be resolved by name (i.e. it's registered).
    public static var isPixelFontAvailable: Bool {
        let font = CTFontCreateWithName(pixelFamily as CFString, 12, nil)
        return (CTFontCopyFamilyName(font) as String) == pixelFamily
    }

    /// Native line metrics for layout that must reserve space before displaying text.
    public static func lineHeight(_ role: ZeusTextRole, choice: ZeusFontChoice, scale: ZeusFontScale = .default) -> CGFloat {
        let font = choice == .pixel && isPixelFontAvailable
            ? pixelCTFont(size: role.size(for: .pixel, scale: scale))
            : CTFontCreateWithName("SFMono-Regular" as CFString, role.size(for: .system, scale: scale), nil)
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// The font for a text role. Falls back to SF Mono if the pixel font isn't registered.
    public static func font(_ role: ZeusTextRole, choice: ZeusFontChoice, scale: ZeusFontScale = .default) -> Font {
        let size = role.size(for: choice, scale: scale)
        switch choice {
        case .pixel where isPixelFontAvailable:
            return Font(pixelCTFont(size: size))
        case .pixel, .system:
            return .system(size: role.size(for: .system, scale: scale), weight: role.weight, design: .monospaced)
        }
    }
}

extension ZeusFonts {
    /// The characters of `text` that the bundled pixel font can't draw (whitespace ignored), in order of
    /// first appearance. Anything listed falls back to a system font and breaks the pixel look, so UI strings
    /// shown in the pixel font should come back empty (Q2 DES-4). Emoji and CJK in agent text are expected.
    public static func pixelFontMissingGlyphs(in text: String) -> [Character] {
        guard let font = bundledPixelFont else { return [] }
        var missing: [Character] = []
        for character in text where !character.isWhitespace && !missing.contains(character) {
            var units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if !CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) { missing.append(character) }
        }
        return missing
    }

    /// The bundled font loaded straight from its file, independent of registration.
    nonisolated(unsafe) private static let bundledPixelFont: CTFont? = {
        guard let url = bundledFontURL,
              let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, 11, nil)
    }()
}

extension ZeusFonts {
    /// The pixel font as a CTFont with **common ligatures off**: pixel UI text should never merge
    /// glyphs (Pixelify Sans's "fi" ligature read as "A"). Departure Mono has a single weight.
    static func pixelCTFont(size: CGFloat) -> CTFont {
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: pixelFamily,
            kCTFontFeatureSettingsAttribute: [[
                kCTFontFeatureTypeIdentifierKey: kLigaturesType,
                kCTFontFeatureSelectorIdentifierKey: kCommonLigaturesOffSelector,
            ]],
        ]
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
    }
}

/// A different pixel font for previews and evaluations (the D9 font spike): a registered family and
/// a point size per role. Sizes should be crisp for the font's grid (whole device pixels per font pixel).
/// It replaces the pixel font only; `.system` (SF Mono) is unaffected.
public struct ZeusFontOverride: Sendable, Equatable {
    public var family: String
    public var sizes: [ZeusTextRole: CGFloat]

    public init(family: String, sizes: [ZeusTextRole: CGFloat]) {
        self.family = family
        self.sizes = sizes
    }

    /// The font for a role; missing sizes fall back to the pixel defaults. Ligatures are off.
    public func font(_ role: ZeusTextRole) -> Font {
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontFeatureSettingsAttribute: [[
                kCTFontFeatureTypeIdentifierKey: kLigaturesType,
                kCTFontFeatureSelectorIdentifierKey: kCommonLigaturesOffSelector,
            ]],
        ]
        let size = sizes[role] ?? role.size(for: .pixel)
        return Font(CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil))
    }
}

extension EnvironmentValues {
    /// Conversation text size. Settings and menus retain the default system size.
    @Entry public var zeusFontScale: ZeusFontScale = .default

    /// Overrides the pixel font (previews and font evaluation only; see `ZeusFontOverride`).
    @Entry public var zeusFontOverride: ZeusFontOverride? = nil
}

/// Applies the Zeus font for a role, honoring `\.zeusFontChoice` and `\.zeusFontOverride`.
struct ZeusFontModifier: ViewModifier {
    @Environment(\.zeusFontChoice) private var choice
    @Environment(\.zeusFontScale) private var scale
    @Environment(\.zeusFontOverride) private var override
    let role: ZeusTextRole

    func body(content: Content) -> some View {
        if choice == .pixel, let override {
            content.font(override.font(role))
        } else {
            content.font(ZeusFonts.font(role, choice: choice, scale: scale))
        }
    }
}

extension View {
    /// Sets the Zeus font for `role`, using the user's font choice from the environment.
    public func zeusFont(_ role: ZeusTextRole) -> some View {
        modifier(ZeusFontModifier(role: role))
    }
}
