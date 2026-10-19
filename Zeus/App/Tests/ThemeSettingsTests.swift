import Foundation
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

// T1: theme selection, the Themes folder, import and live reload. Every test has its own temporary Characters
// folder (the Themes folder sits next to it) and UserDefaults suite; nothing touches the user's real folders.

@MainActor private final class ThemeFixture {
    let suite = TestDefaults.suite("zeus-t1")
    let defaults: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-t1-\(UUID())", isDirectory: true)
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-t1-src-\(UUID())", isDirectory: true)
    let settings: AppSettings
    let model: LibraryImportModel
    var themes: URL { root.appendingPathComponent("Themes", isDirectory: true) }

    init() {
        defaults = UserDefaults(suiteName: suite) ?? .standard
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        settings = AppSettings(defaults: defaults, userDirectory: root.appendingPathComponent("Characters", isDirectory: true))
        model = .themes(settings)
    }

    func cleanup() {
        settings.stopWatchingUserFolders()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: source)
        defaults.removePersistentDomain(forName: suite)
    }

    static func json(id: String, name: String, appearance: String = "dark", colors: String = "") -> String {
        #"{ "id": "\#(id)", "name": "\#(name)", "appearance": "\#(appearance)", "colors": { \#(colors) } }"#
    }

    @discardableResult func file(_ name: String, _ json: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }
}

@MainActor @Suite(.serialized) struct ThemeSettingsTests {
    @Test func classicByDefaultAndTheSelectionPersists() throws {
        let f = ThemeFixture(); defer { f.cleanup() }
        #expect(f.settings.currentThemeID == "classic" && f.settings.currentTheme == .classic)
        #expect(f.settings.availableThemes.map(\.id).starts(with: ["classic", "midnight", "parchment"]))
        #expect(f.settings.setTheme(id: "phosphor"))
        #expect(f.settings.currentTheme.palette(for: .light).panel == f.settings.availableThemes.first { $0.id == "phosphor" }?.palette(for: .dark).panel)
        let reloaded = AppSettings(defaults: f.defaults, userDirectory: f.root.appendingPathComponent("Characters"))
        #expect(reloaded.currentThemeID == "phosphor")
        #expect(f.defaults.string(forKey: "appearance.theme") == "phosphor")
        #expect(!f.settings.setTheme(id: "nope") && f.settings.currentThemeID == "phosphor")
    }

    @Test func agentSeamListsAndSetsThemes() {
        let f = ThemeFixture(); defer { f.cleanup() }
        let seam: any ThemeControlling = f.settings
        #expect(seam.availableThemes.contains { $0.id == "sorbet" })
        #expect(seam.setTheme(id: "sorbet") && seam.currentThemeID == "sorbet")
    }

    @Test func testsWithoutAFolderNeverSeeTheRealOne() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: TestDefaults.suite("zeus-t1-none")) ?? .standard, userDirectory: nil)
        #expect(settings.userThemeDirectory == nil)
        #expect(settings.availableThemes.map(\.id) == ZeusThemeLibrary.bundledOrder)
    }

    @Test func userThemesReloadAndARemovedOneFallsBackAndReturns() throws {
        let f = ThemeFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.themes, withIntermediateDirectories: true)
        let url = f.themes.appendingPathComponent("ink.json")
        try Data(ThemeFixture.json(id: "ink", name: "Ink", colors: ##""panel": "#101418""##).utf8).write(to: url)
        f.settings.reloadThemes()
        #expect(f.settings.setTheme(id: "ink"))
        try FileManager.default.removeItem(at: url)
        f.settings.reloadThemes()
        #expect(f.settings.currentThemeID == "classic")
        try Data(ThemeFixture.json(id: "ink", name: "Ink Two").utf8).write(to: url)
        f.settings.reloadThemes()
        #expect(f.settings.currentThemeID == "ink" && f.settings.currentTheme.name == "Ink Two")
    }

    @Test func brokenFilesAreListedInPlainWords() throws {
        let f = ThemeFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.themes, withIntermediateDirectories: true)
        try Data(ThemeFixture.json(id: "x", name: "X", colors: #""panel": "navy""#).utf8).write(to: f.themes.appendingPathComponent("x.json"))
        f.settings.reloadThemes()
        #expect(f.settings.themeProblemLines.map(\.text) == ["x.json wasn't loaded. \"panel\" in \"colors\" isn't a color (got navy). Use #RRGGBB, or #RRGGBBAA for see-through."])
    }
}

@MainActor @Suite(.serialized) struct ThemeImportModelTests {
    @Test func importSelectsAndFlagsLowContrast() throws {
        let f = ThemeFixture(); defer { f.cleanup() }
        let fog = ThemeFixture.json(id: "fog", name: "Fog", appearance: "light", colors: ##""text": "#CCCCCC""##)
        f.model.importFile(at: try f.file("Fog.json", fog))
        guard case .added(let message, let notes)? = f.model.notice else { Issue.record("\(String(describing: f.model.notice))"); return }
        #expect(message == "Added Fog." && notes.first?.hasPrefix("Some text may be hard to read:") == true)
        #expect(f.settings.currentThemeID == "fog" && f.settings.currentTheme.isLowContrast)
        #expect(FileManager.default.fileExists(atPath: f.themes.appendingPathComponent("fog.json").path))
    }

    @Test func builtInIDAsksFirst() throws {
        let f = ThemeFixture(); defer { f.cleanup() }
        let url = try f.file("s.json", ThemeFixture.json(id: "sorbet", name: "My Sorbet", appearance: "light"))
        f.model.importFile(at: url)
        #expect(f.model.replacePrompt == "Replace the built-in Sorbet theme?")
        f.model.cancelReplace()
        #expect(f.settings.currentThemeID == "classic")
        f.model.importFile(at: url)
        f.model.confirmReplace()
        #expect(f.settings.currentThemeID == "sorbet" && f.settings.currentTheme.name == "My Sorbet")
    }

    @Test func invalidThemeSaysWhatIsWrongAndExampleNeverLoads() throws {
        let f = ThemeFixture(); defer { f.cleanup() }
        f.model.importFile(at: try f.file("Bad.json", #"{ "id": "bad", "name": "Bad", "appearance": "dark", "colors": {}, "avatar": "ghost" }"#))
        guard case .failed(let file, let lines)? = f.model.notice else { Issue.record("expected a failure"); return }
        #expect(file == "Bad.json" && lines.first?.hasPrefix("\"avatar\" isn't a theme setting.") == true)
        let example = try #require(try f.model.exampleFile())
        #expect(example.lastPathComponent == "Example Theme.json")
        f.settings.reloadThemes()
        #expect(!f.settings.availableThemes.contains { $0.name == "Harbor" } && f.settings.themeProblems.isEmpty)
        #expect(try f.model.folder() == f.themes)
    }

    @Test func watcherReloadsThemes() async throws {
        let f = ThemeFixture(); defer { f.cleanup() }
        f.settings.startWatchingUserFolders()
        try Data(ThemeFixture.json(id: "late", name: "Late").utf8).write(to: f.themes.appendingPathComponent("late.json"))
        let deadline = Date().addingTimeInterval(10)
        while !f.settings.availableThemes.contains(where: { $0.id == "late" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(f.settings.availableThemes.contains { $0.id == "late" })
    }
}
