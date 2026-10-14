import Foundation
import SwiftUI
import Testing
@testable import ZeusDesign

// T1: color themes. Parsing, fallback, the library, resolution with Increase Contrast, the contrast audit over
// every bundled theme, and importing.

private func load(_ json: String, source: String = "t.json") -> (ZeusThemeDefinition?, [ZeusThemeIssue]) {
    ZeusThemeDefinition.load(data: Data(json.utf8), source: source)
}

private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-t1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct ZeusThemeParsingTests {
    @Test func singleAppearanceIsFixedAndFallsBackPerField() throws {
        let (theme, issues) = load(##"{ "id": "ink", "name": "Ink", "author": "Alex", "appearance": "dark", "colors": { "panel": "#101010", "accent": "#FFCC0080" } }"##)
        #expect(issues.isEmpty, "\(issues)")
        let ink = try #require(theme)
        #expect(ink.fixedAppearance == .dark && ink.author == "Alex")
        // Fixed dark: the light system scheme still gets the dark palette.
        let palette = ink.palette(for: .light)
        #expect(palette.panel == Color(hex: 0x101010))
        #expect(palette.accent == Color(hex: 0xFFCC00, opacity: 128.0 / 255))
        #expect(palette.text == ZeusPalette.dark.text, "missing fields keep the base palette of that appearance")
    }

    @Test func darkAndLightFollowTheSystem() throws {
        let (theme, issues) = load(##"{ "id": "duo", "name": "Duo", "dark": { "panel": "#111111" }, "light": { "panel": "#EEEEEE" } }"##)
        #expect(issues.isEmpty, "\(issues)")
        let duo = try #require(theme)
        #expect(duo.fixedAppearance == nil)
        #expect(duo.palette(for: .dark).panel == Color(hex: 0x111111) && duo.palette(for: .light).panel == Color(hex: 0xEEEEEE))
        #expect(duo.palette(for: .light).text == ZeusPalette.light.text)
    }

    @Test func increaseContrastBeatsTheThemeUnlessItHasItsOwn() throws {
        let plain = try #require(load(##"{ "id": "a", "name": "A", "appearance": "light", "colors": { "panel": "#FAFAFA" } }"##).0)
        #expect(plain.palette(for: .light, contrast: .increased) == .lightHighContrast)
        #expect(plain.palette(for: .dark, contrast: .increased) == .lightHighContrast, "a fixed light theme stays light")
        let own = try #require(load(##"{ "id": "b", "name": "B", "appearance": "dark", "colors": {}, "darkHighContrast": { "panel": "#000000" } }"##).0)
        #expect(own.palette(for: .dark, contrast: .increased).panel == Color(hex: 0x000000))
        #expect(own.palette(for: .dark, contrast: .increased).text == ZeusPalette.darkHighContrast.text)
    }

    @Test func environmentResolvesThroughTheTheme() throws {
        var env = EnvironmentValues()
        env.colorScheme = .light
        #expect(env.zeusPalette == .light, "Classic by default")
        env.zeusTheme = try #require(load(##"{ "id": "n", "name": "N", "appearance": "dark", "colors": { "panel": "#202020" } }"##).0)
        #expect(env.zeusPalette.panel == Color(hex: 0x202020))
        env._colorSchemeContrast = .increased
        #expect(env.zeusPalette == .darkHighContrast)
    }

    @Test func problemsAreNamedInPlainWords() {
        func errors(_ json: String) -> [String] { load(json).1.filter { $0.severity == .error }.map(\.message) }
        #expect(errors(##"{ "id": "x", "name": "X", "appearance": "dark", "colors": {}, "avatar": "zeus" }"##).first?.hasPrefix("\"avatar\" isn't a theme setting.") == true)
        #expect(errors(##"{ "id": "x", "name": "X", "appearance": "dark", "colors": { "sprite": "#FFFFFF" } }"##).first?.hasPrefix("\"sprite\" in \"colors\" isn't a theme color.") == true)
        #expect(errors(##"{ "id": "x", "name": "X", "appearance": "dark", "colors": { "panel": "navy" } }"##)
                == ["\"panel\" in \"colors\" isn't a color (got navy). Use #RRGGBB, or #RRGGBBAA for see-through."])
        #expect(errors(##"{ "id": "x", "name": "X", "appearance": "dark", "colors": { "sessionColors": ["#FFFFFF"] } }"##).first?.contains("must be a list of 4 colors") == true)
        #expect(errors(##"{ "id": "x", "name": "X", "appearance": "dusk", "colors": {} }"##) == ["\"appearance\" must be \"dark\" or \"light\"."])
        #expect(errors(##"{ "id": "x", "name": "X", "dark": {} }"##) == ["A theme that follows the system needs both \"dark\" and \"light\"."])
        #expect(errors(##"{ "id": "bad id", "name": "X", "appearance": "dark", "colors": {} }"##).first?.hasPrefix("\"id\" must be") == true)
        let syntax = errors("{\n  \"id\": \"x\"\n  \"name\": \"X\"\n}")
        #expect(syntax.first?.hasPrefix("This file isn't valid JSON:") == true && syntax.first?.contains("line 3") == true, "\(syntax)")
        // Notes are ignored anywhere.
        #expect(errors(##"{ "_help": "hi", "id": "x", "name": "X", "appearance": "dark", "colors": { "_help": "hi" } }"##).isEmpty)
    }

    @Test func lowContrastStillLoadsButIsFlagged() throws {
        let (theme, issues) = load(##"{ "id": "fog", "name": "Fog", "appearance": "light", "colors": { "text": "#CCCCCC", "agentBubble": "#FFFFFF" } }"##)
        #expect(issues.isEmpty)
        let fog = try #require(theme)
        #expect(fog.isLowContrast)
        #expect(fog.contrastProblems.first?.hasPrefix("body text on agent bubble is 1.6:1; it needs 4.5:1") == true, "\(fog.contrastProblems)")
        #expect(ZeusThemeImport.lowContrastCaption(fog)?.hasPrefix("Some text may be hard to read: body text on agent bubble") == true)
    }
}

@Suite struct ZeusThemeLibraryTests {
    @Test func bundledThemesLoadInOrderWithoutProblems() {
        let library = ZeusThemeLibrary.load(userDirectory: nil)
        #expect(library.problems.isEmpty, "\(library.problems)")
        #expect(library.themes.map(\.id) == ZeusThemeLibrary.bundledOrder)
        #expect(library.themes.first?.id == ZeusThemeLibrary.defaultThemeID)
    }

    /// Midnight and Parchment are exactly today's palettes, so choosing either changes nothing but following the system.
    @Test func midnightAndParchmentAreTheClassicPalettes() throws {
        let library = ZeusThemeLibrary.load(userDirectory: nil)
        // Hex alpha is in 1/255 steps, so the 35% and 25% shadows are compared within one step.
        func same(_ themed: ZeusPalette, _ builtIn: ZeusPalette) -> Bool {
            var themed = themed
            let alpha = { (c: Color) in Double(c.resolve(in: EnvironmentValues()).opacity) }
            guard abs(alpha(themed.shadow) - alpha(builtIn.shadow)) <= 1.0 / 255 else { return false }
            themed.shadow = builtIn.shadow
            return themed == builtIn
        }
        #expect(same(try #require(library.theme(id: "midnight")).palette(for: .light), .dark))
        #expect(same(try #require(library.theme(id: "parchment")).palette(for: .dark), .light))
    }

    /// Every bundled theme, in every look it has, passes the same WCAG audit as the built-in palettes.
    @Test func everyBundledThemePassesTheContrastAudit() {
        for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
            #expect(!theme.isLowContrast, "\(theme.id): \(theme.contrastProblems)")
            for scheme in [ColorScheme.light, .dark] {
                let dark = (theme.fixedAppearance ?? scheme) == .dark
                for contrast in [ColorSchemeContrast.standard, .increased] {
                    let failures = ZeusContrast.failures(theme.palette(for: scheme, contrast: contrast), dark: dark, highContrast: contrast == .increased)
                    #expect(failures.isEmpty, "\(theme.id) \(scheme) \(contrast): \(failures)")
                }
            }
        }
    }

    @Test func userThemesOverrideByIDAndUnderscoreIDsAreSkipped() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(##"{ "id": "phosphor", "name": "My Phosphor", "appearance": "dark", "colors": {} }"##.utf8).write(to: dir.appendingPathComponent("p.json"))
        try ZeusThemeExample.write(into: dir)
        try Data(##"{ "id": "_notes", "whatever": 1 }"##.utf8).write(to: dir.appendingPathComponent("notes.json"))
        try Data(##"{ "id": "mine", "name": "Mine", "appearance": "light", "colors": {} }"##.utf8).write(to: dir.appendingPathComponent("mine.json"))
        try Data("{ broken".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let library = ZeusThemeLibrary.load(userDirectory: dir)
        #expect(library.theme(id: "phosphor")?.name == "My Phosphor")
        #expect(library.themes.filter { $0.id == "phosphor" }.count == 1)
        #expect(library.theme(id: "_example") == nil && library.theme(id: "mine") != nil)
        #expect(library.themes.last?.id == "mine", "user themes come after the bundled ones")
        #expect(library.problems.map(\.source) == ["broken.json"])
    }

    @Test func exampleIsValidOnceRenamedAndPassesContrast() throws {
        let renamed = ZeusThemeExample.json.replacingOccurrences(of: #""id": "_example""#, with: #""id": "harbor""#)
        let (theme, issues) = load(renamed)
        #expect(issues.isEmpty, "\(issues)")
        #expect(theme?.isLowContrast == false, "\(theme?.contrastProblems ?? [])")
    }
}

@Suite struct ZeusThemeImportTests {
    let builtIn = ZeusThemeLibrary.load(userDirectory: nil).themes

    @Test func newThemeGoesInUnderItsID() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data(##"{ "id": "dawn", "name": "Dawn", "appearance": "light", "colors": {} }"##.utf8)
        let plan = try ZeusThemeImport.plan(data: data, source: "Dawn.json", userDirectory: dir, builtIn: builtIn).get()
        #expect(plan.fileName == "dawn.json" && plan.conflict == nil)
        try ZeusThemeImport.install(plan, into: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("dawn.json")) == data)
        #expect(ZeusThemeImport.doneMessage(plan) == "Added Dawn.")
    }

    @Test func builtInIDAsksFirstAndInvalidCopiesNothing() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try ZeusThemeImport.plan(data: Data(##"{ "id": "sorbet", "name": "My Sorbet", "appearance": "light", "colors": {} }"##.utf8),
                                            source: "s.json", userDirectory: dir, builtIn: builtIn).get()
        #expect(ZeusThemeImport.replacePrompt(try #require(plan.conflict)) == "Replace the built-in Sorbet theme?")
        let bad = ZeusThemeImport.plan(data: Data(##"{ "id": "x", "name": "X", "appearance": "dark", "colors": { "panel": "blue" } }"##.utf8),
                                       source: "x.json", userDirectory: dir, builtIn: builtIn)
        guard case .failure(let failure) = bad else { Issue.record("expected a failure"); return }
        #expect(failure.lines == ["\"panel\" in \"colors\" isn't a color (got blue). Use #RRGGBB, or #RRGGBBAA for see-through."])
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
        guard case .failure(.reservedID("_example")) = ZeusThemeImport.plan(data: Data(ZeusThemeExample.json.utf8), source: "e.json", userDirectory: dir, builtIn: builtIn) else {
            Issue.record("the example can't be imported as is"); return
        }
    }
}
