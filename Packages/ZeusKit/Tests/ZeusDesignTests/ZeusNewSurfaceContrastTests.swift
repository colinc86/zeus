import SwiftUI
import Testing
@testable import ZeusDesign

/// D18: the 0.1.8 surfaces (message links, the status strip, quiet thread lines, Settings › Privacy and ghost-mode text)
/// meet WCAG AA in every bundled theme, light and dark, with and without Increase Contrast: 4.5:1 for text (7:1 under
/// Increase Contrast), 3:1 for the strip's 12-px icons and its divider. A failure names the theme, the look and the role.
struct ZeusNewSurfaceContrastTests {
    static let themeIDs = ZeusThemeLibrary.load(userDirectory: nil).themes.map(\.id)

    /// "olympus light standard: link on agent bubble: 1.84:1 (needs 4.5)".
    static func failures(_ id: String) -> [String] {
        guard let theme = ZeusThemeLibrary.load(userDirectory: nil).themes.first(where: { $0.id == id }) else { return ["\(id): missing"] }
        var found: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let dark = (theme.fixedAppearance ?? scheme) == .dark
                let pairs = ZeusContrast.newSurfacePairs(theme.palette(for: scheme, contrast: contrast), dark: dark, highContrast: contrast == .increased)
                found += pairs.filter { !$0.passes }
                    .map { "\(id) \(scheme == .dark ? "dark" : "light") \(contrast == .increased ? "increased" : "standard"): \($0)" }
            }
        }
        return found
    }

    @Test(arguments: themeIDs)
    func newSurfacesMeetWCAG(_ id: String) {
        let failures = Self.failures(id)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func everyBundledThemeIsAudited() {
        #expect(Set(Self.themeIDs) == ["classic", "midnight", "parchment", "olympus", "phosphor", "pocket", "sorbet"])
        #expect(ZeusContrast.newSurfacePairs(.light, dark: false, highContrast: false).count == 17)
    }

    /// The `link` role defaults to the theme's accent; a theme file's `link` and `divider` replace the defaults.
    @Test func linkAndDividerRolesDefaultAndOverride() throws {
        let plain = try #require(ZeusThemeDefinition.load(data: Data(##"{ "format": 1, "id": "p", "name": "P", "appearance": "dark", "colors": { "accent": "#FFAA00" } }"##.utf8), source: "p.json").theme)
        #expect(plain.palette(for: .dark).link == Color(hex: 0xFFAA00))
        #expect(plain.palette(for: .dark).divider == plain.palette(for: .dark).secondaryText.opacity(ZeusPalette.dividerOpacity))
        let own = try #require(ZeusThemeDefinition.load(data: Data(##"{ "format": 1, "id": "o", "name": "O", "appearance": "light", "colors": { "link": "#123456", "divider": "#654321" } }"##.utf8), source: "o.json").theme)
        #expect(own.palette(for: .light).link == Color(hex: 0x123456))
        #expect(own.palette(for: .light).divider == Color(hex: 0x654321))
        #expect(ZeusPalette.light.userBubbleText.link == ZeusPalette.light.onUserBubble)
    }

    /// Links in messages use the `link` role, underlined.
    @Test func markdownLinksUseTheLinkRole() {
        let text = ZeusMarkdown.attributed("See https://example.com now", choice: .pixel, palette: .light)
        let run = text.runs.first { $0.link != nil }
        #expect(run?.foregroundColor == ZeusPalette.light.link && run?.underlineStyle == .single)
        #expect(ZeusPalette.light.link != ZeusPalette.light.accent)
    }
}
