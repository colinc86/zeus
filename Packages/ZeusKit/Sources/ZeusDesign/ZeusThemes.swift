import Foundation
import SwiftUI
import ZeusProtocol

// Color themes (T1, docs/design/THEME_FORMAT.md): a theme is a `ZeusPalette` from a JSON file. It recolors the
// conversation panel, the peek bubble, the typing indicator, Zeus's popovers and Settings, never the character
// sprites. Views keep reading `@Environment(\.zeusPalette)`; the app sets `\.zeusTheme` once at each root.

/// A color theme: a palette for one fixed appearance, or one for each so it follows the system.
public struct ZeusThemeDefinition: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let author: String?
    /// Set when the theme has a single look ("appearance": "dark" or "light"), whatever the system uses.
    public let fixedAppearance: ColorScheme?
    let darkPalette: ZeusPalette?
    let lightPalette: ZeusPalette?
    let darkHighContrastPalette: ZeusPalette?
    let lightHighContrastPalette: ZeusPalette?
    /// The contrast pairs this theme's own palettes miss, in plain words. Empty for every bundled theme.
    public let contrastProblems: [String]

    /// True when some text or control in this theme is below WCAG AA (Settings shows a "Low contrast" tag).
    public var isLowContrast: Bool { !contrastProblems.isEmpty }

    /// The palette for a color scheme and contrast. A fixed-appearance theme ignores the scheme. Increase Contrast
    /// uses the theme's high-contrast colors if it has them, else Zeus's own: accessibility wins over the theme.
    public func palette(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> ZeusPalette {
        let dark = (fixedAppearance ?? scheme) == .dark
        if contrast == .increased {
            return dark ? (darkHighContrastPalette ?? .darkHighContrast) : (lightHighContrastPalette ?? .lightHighContrast)
        }
        return dark ? (darkPalette ?? .dark) : (lightPalette ?? .light)
    }

    /// The default: Midnight in dark mode, Parchment in light mode. Built in code, so it can never fail to load.
    public static let classic = ZeusThemeDefinition(id: "classic", name: "Classic", author: nil, fixedAppearance: nil,
                                                     darkPalette: .dark, lightPalette: .light,
                                                     darkHighContrastPalette: nil, lightHighContrastPalette: nil, contrastProblems: [])
}

extension EnvironmentValues {
    /// The selected color theme. Set it once at each root (panel, peek, popovers, Settings):
    /// `.environment(\.zeusTheme, settings.currentTheme)`. `\.zeusPalette` resolves through it.
    @Entry public var zeusTheme: ZeusThemeDefinition = .classic
}

/// A problem in a theme file, in plain words.
public struct ZeusThemeIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Hashable { case error, warning }
    public var severity: Severity
    /// The file it was found in.
    public var source: String
    /// A whole sentence saying what's wrong and where.
    public var message: String
    public init(severity: Severity, source: String, message: String) {
        self.severity = severity
        self.source = source
        self.message = message
    }
    public var description: String { "\(source): \(severity.rawValue): \(message)" }
}

// MARK: - Parsing

extension ZeusThemeDefinition {
    /// The top-level keys a theme file may have (besides `"_…"` notes).
    static let topLevelKeys: Set<String> = ["format", "id", "name", "author", "appearance", "colors", "dark", "light",
                                            "darkHighContrast", "lightHighContrast"]

    /// Parses and validates a theme file. Returns nil for `theme` when there are errors.
    public static func load(data: Data, source: String) -> (theme: ZeusThemeDefinition?, issues: [ZeusThemeIssue]) {
        var issues: [ZeusThemeIssue] = []
        func error(_ message: String) { issues.append(ZeusThemeIssue(severity: .error, source: source, message: message)) }

        let object: [String: Any]
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, [ZeusThemeIssue(severity: .error, source: source, message: "A theme file must be one JSON object, starting with {.")])
            }
            object = root
        } catch {
            let detail = ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
            var message = "This file isn't valid JSON: \(detail)"
            if let last = message.last, !".?!".contains(last) { message += "." }
            if detail.hasPrefix("Unexpected character") { message += " Check for a missing comma or quote just before it." }
            return (nil, [ZeusThemeIssue(severity: .error, source: source, message: message)])
        }

        for key in object.keys.sorted() where !key.hasPrefix("_") && !topLevelKeys.contains(key) {
            error("\"\(key)\" isn't a theme setting. A theme has id, name, author, and either appearance with colors, or dark and light. Themes only recolor Zeus's panels and Settings; characters keep their own colors.")
        }
        if let format = object["format"] as? Int, format > 1 { error("This theme uses format \(format), which is newer than this version of Zeus supports (1).") }

        let id = object["id"] as? String ?? ""
        if id.isEmpty || id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            error("\"id\" must be a name made of letters, digits, - and _ (got \(object["id"].map { "\($0)" } ?? "nothing")).")
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty { error("\"name\" is missing: give the theme a name to show in Settings.") }
        let author = object["author"] as? String

        var fixed: ColorScheme?
        var dark: ZeusPalette?, light: ZeusPalette?, darkHC: ZeusPalette?, lightHC: ZeusPalette?
        if let appearance = object["appearance"] {
            switch appearance as? String {
            case "dark": fixed = .dark
            case "light": fixed = .light
            default: error("\"appearance\" must be \"dark\" or \"light\".")
            }
            if object["dark"] != nil || object["light"] != nil {
                error("Use either \"appearance\" with \"colors\", or \"dark\" and \"light\", not both.")
            }
            if let block = object["colors"] {
                let base: ZeusPalette = fixed == .light ? .light : .dark
                let palette = colors(block, named: "colors", base: base, error: error)
                if fixed == .light { light = palette } else { dark = palette }
            } else {
                error("\"colors\" is missing: a theme with \"appearance\" lists its colors there.")
            }
        } else if object["dark"] != nil || object["light"] != nil {
            if object["colors"] != nil { error("\"colors\" goes with \"appearance\". To follow the system, put colors in \"dark\" and \"light\" instead.") }
            guard let darkBlock = object["dark"], let lightBlock = object["light"] else {
                error("A theme that follows the system needs both \"dark\" and \"light\".")
                return (nil, issues)
            }
            dark = colors(darkBlock, named: "dark", base: .dark, error: error)
            light = colors(lightBlock, named: "light", base: .light, error: error)
        } else {
            error("Add \"appearance\" (\"dark\" or \"light\") with \"colors\", or \"dark\" and \"light\" blocks to follow the system.")
        }
        if let block = object["darkHighContrast"] {
            if dark == nil && issues.isEmpty { error("\"darkHighContrast\" needs a dark look: this theme has none.") }
            darkHC = colors(block, named: "darkHighContrast", base: .darkHighContrast, error: error)
        }
        if let block = object["lightHighContrast"] {
            if light == nil && issues.isEmpty { error("\"lightHighContrast\" needs a light look: this theme has none.") }
            lightHC = colors(block, named: "lightHighContrast", base: .lightHighContrast, error: error)
        }
        guard !issues.contains(where: { $0.severity == .error }) else { return (nil, issues) }

        var problems: [String] = []
        for (palette, isDark, hc) in [(dark, true, false), (light, false, false), (darkHC, true, true), (lightHC, false, true)] {
            guard let palette else { continue }
            problems += ZeusContrast.failures(palette, dark: isDark, highContrast: hc).map(\.plain)
        }
        let theme = ZeusThemeDefinition(id: id, name: name, author: author, fixedAppearance: fixed,
                                        darkPalette: dark, lightPalette: light,
                                        darkHighContrastPalette: darkHC, lightHighContrastPalette: lightHC, contrastProblems: problems)
        return (theme, issues)
    }

    /// A colors block over `base`: listed fields replace the base's, missing ones keep it.
    private static func colors(_ block: Any, named name: String, base: ZeusPalette, error: (String) -> Void) -> ZeusPalette {
        guard let fields = block as? [String: Any] else {
            error("\"\(name)\" must be a set of colors, like { \"panel\": \"#1E1A2E\" }.")
            return base
        }
        var palette = base
        // A theme's link and divider default from its own accent and secondary text, never the base palette's (D18).
        palette.linkColor = nil
        palette.dividerColor = nil
        for key in fields.keys.sorted() where !key.hasPrefix("_") {
            let value = fields[key]
            if key == "sessionColors" {
                let list = (value as? [Any])?.compactMap { ($0 as? String).flatMap(Color.init(themeHex:)) } ?? []
                if list.count == 4, (value as? [Any])?.count == 4 { palette.sessionColors = list } else {
                    error("\"sessionColors\" in \"\(name)\" must be a list of 4 colors, like [\"#7AD7FF\", \"#F6C544\", \"#8DE08A\", \"#FF9FD0\"].")
                }
                continue
            }
            guard ZeusPalette.colorKeys.contains(key) else {
                error("\"\(key)\" in \"\(name)\" isn't a theme color. Theme colors are \(ZeusPalette.colorKeys.joined(separator: ", ")) and sessionColors.")
                continue
            }
            guard let text = value as? String, let color = Color(themeHex: text) else {
                error("\"\(key)\" in \"\(name)\" isn't a color (got \(value.map { "\($0)" } ?? "nothing")). Use #RRGGBB, or #RRGGBBAA for see-through.")
                continue
            }
            palette.setColor(key, color)
        }
        return palette
    }
}

extension ZeusPalette {
    /// The single-color fields a theme can set, in declaration order (plus the `sessionColors` list).
    public static let colorKeys = ["outline", "frame", "panel", "text", "secondaryText", "title", "accent", "onAccent",
                                   "secondaryFill", "onSecondary", "destructive", "onDestructive", "field", "fieldBorder",
                                   "track", "fill", "badge", "onBadge", "shadow", "agentBubble", "userBubble", "onUserBubble",
                                   "focusRing", "positive", "link", "divider"]

    mutating func setColor(_ key: String, _ color: Color) {
        switch key {
        case "outline": outline = color
        case "frame": frame = color
        case "panel": panel = color
        case "text": text = color
        case "secondaryText": secondaryText = color
        case "title": title = color
        case "accent": accent = color
        case "onAccent": onAccent = color
        case "secondaryFill": secondaryFill = color
        case "onSecondary": onSecondary = color
        case "destructive": destructive = color
        case "onDestructive": onDestructive = color
        case "field": field = color
        case "fieldBorder": fieldBorder = color
        case "track": track = color
        case "fill": fill = color
        case "badge": badge = color
        case "onBadge": onBadge = color
        case "shadow": shadow = color
        case "agentBubble": agentBubble = color
        case "userBubble": userBubble = color
        case "onUserBubble": onUserBubble = color
        case "focusRing": focusRing = color
        case "positive": positive = color
        case "link": linkColor = color
        case "divider": dividerColor = color
        default: break
        }
    }
}

extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" (case-insensitive), in sRGB. Nil for anything else.
    public init?(themeHex text: String) {
        let hex = text.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#"), [7, 9].contains(hex.count), let value = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        let rgb = hex.count == 9 ? value >> 8 : value
        let alpha = hex.count == 9 ? Double(value & 0xFF) / 255 : 1
        self.init(hex: UInt32(rgb & 0xFFFFFF), opacity: alpha)
    }
}

// MARK: - Library

/// The themes available to the app: Classic, the bundled ones, then the user's. A user file with the same `id`
/// replaces a bundled theme; ids starting with `_` are skipped (the example file).
public struct ZeusThemeLibrary: Sendable {
    public static let defaultThemeID = ZeusThemeDefinition.classic.id
    /// Classic first, then the bundled files in this order.
    public static let bundledOrder = ["classic", "midnight", "parchment", "olympus", "phosphor", "pocket", "sorbet"]

    public private(set) var themes: [ZeusThemeDefinition]
    /// Problems in theme files, including ones that didn't load.
    public private(set) var problems: [ZeusThemeIssue]

    /// The bundled theme files.
    public static var bundledDirectory: URL? { Bundle.module.url(forResource: "Themes", withExtension: nil) }

    public static func load(userDirectory: URL?) -> ZeusThemeLibrary {
        var byID: [String: ZeusThemeDefinition] = [ZeusThemeDefinition.classic.id: .classic]
        var problems: [ZeusThemeIssue] = []
        for directory in [bundledDirectory, userDirectory].compactMap(\.self) {
            let (themes, found) = loadDirectory(directory)
            problems += found
            for theme in themes { byID[theme.id] = theme }
        }
        let rank = Dictionary(uniqueKeysWithValues: bundledOrder.enumerated().map { ($1, $0) })
        let sorted = byID.values.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return ZeusThemeLibrary(themes: sorted, problems: problems)
    }

    /// Every `*.json` theme in `directory` (not recursive), in file name order.
    public static func loadDirectory(_ directory: URL) -> (themes: [ZeusThemeDefinition], issues: [ZeusThemeIssue]) {
        var themes: [ZeusThemeDefinition] = []
        var issues: [ZeusThemeIssue] = []
        var seen: [String: String] = [:]
        for url in UserLibraryFolder.jsonFiles(in: directory) {
            guard let data = try? Data(contentsOf: url) else {
                issues.append(ZeusThemeIssue(severity: .error, source: url.lastPathComponent, message: "Zeus couldn't read this file."))
                continue
            }
            if let id = UserLibraryFolder.declaredID(in: data), UserLibraryFolder.isReservedID(id) { continue }
            let (theme, found) = ZeusThemeDefinition.load(data: data, source: url.lastPathComponent)
            issues += found
            guard let theme else { continue }
            if let other = seen[theme.id] {
                issues.append(ZeusThemeIssue(severity: .warning, source: url.lastPathComponent,
                                             message: "\(other) also uses the id \"\(theme.id)\"; this file wins."))
                themes.removeAll { $0.id == theme.id }
            }
            seen[theme.id] = url.lastPathComponent
            themes.append(theme)
        }
        return (themes, issues)
    }

    public func theme(id: String) -> ZeusThemeDefinition? { themes.first { $0.id == id } }
}

// MARK: - Import

/// Validates a theme file and works out where it goes in the user's Themes folder, before anything is copied.
public enum ZeusThemeImport {
    public enum Conflict: Equatable, Sendable {
        case builtIn(name: String)
        case yours(name: String, fileName: String)
    }

    public struct Plan: Sendable {
        public let theme: ZeusThemeDefinition
        public let fileName: String
        public let conflict: Conflict?
        public let alreadyInstalled: Bool
        let data: Data
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalid([ZeusThemeIssue])
        case reservedID(String)

        /// What's wrong, one plain sentence per line.
        public var lines: [String] {
            switch self {
            case .invalid(let issues): issues.filter { $0.severity == .error }.map(\.message)
            case .reservedID(let id):
                ["Its id \"\(id)\" starts with _, which Zeus keeps for examples. Change \"id\" to a name of your own, using letters, digits, - and _."]
            }
        }
    }

    public static func plan(data: Data, source: String, userDirectory: URL, builtIn: [ZeusThemeDefinition]) -> Result<Plan, Failure> {
        if let id = UserLibraryFolder.declaredID(in: data), UserLibraryFolder.isReservedID(id) { return .failure(.reservedID(id)) }
        let (loaded, issues) = ZeusThemeDefinition.load(data: data, source: source)
        guard let theme = loaded else { return .failure(.invalid(issues)) }
        let place = UserLibraryFolder.placement(id: theme.id, data: data, in: userDirectory)
        let conflict: Conflict? = if let mine = place.replaces {
            .yours(name: mine.name, fileName: mine.fileName)
        } else if place.alreadyInstalled {
            nil
        } else {
            builtIn.first { $0.id == theme.id }.map { Conflict.builtIn(name: $0.name) }
        }
        return .success(Plan(theme: theme, fileName: place.fileName, conflict: conflict, alreadyInstalled: place.alreadyInstalled, data: data))
    }

    @discardableResult
    public static func install(_ plan: Plan, into userDirectory: URL) throws -> URL {
        try UserLibraryFolder.install(plan.data, as: plan.fileName, into: userDirectory, alreadyInstalled: plan.alreadyInstalled)
    }

    public static func replacePrompt(_ conflict: Conflict) -> String {
        switch conflict {
        case .builtIn(let name): "Replace the built-in \(name) theme?"
        case .yours(let name, _): "Replace your \(name) theme?"
        }
    }

    public static func doneMessage(_ plan: Plan) -> String {
        plan.alreadyInstalled ? "\(plan.theme.name) is already added." : "Added \(plan.theme.name)."
    }

    /// The caption under a low-contrast theme, e.g. "Some text may be hard to read: …".
    public static func lowContrastCaption(_ theme: ZeusThemeDefinition) -> String? {
        guard let first = theme.contrastProblems.first else { return nil }
        let more = theme.contrastProblems.count - 1
        return "Some text may be hard to read: \(first)" + (more > 0 ? " (and \(more) more)." : ".")
    }
}

/// A working example theme with a note on every color, written by Settings › Appearance › Open Example. Its
/// `"_example"` id keeps it out of the picker until the user gives it one of their own.
public enum ZeusThemeExample {
    public static let fileName = "Example Theme.json"

    public static let json = #"""
    {
      "_help": "An example theme. Zeus skips it because its id starts with _. To make your own: save a copy in this folder with a new name, change \"id\" and \"name\", and it appears in Settings › Appearance. Zeus reloads the folder whenever a file changes. Themes recolor the conversation panel, the speech bubble and Settings; characters keep their own colors. Full reference: docs/design/THEME_FORMAT.md in the Zeus repository.",
      "format": 1,
      "id": "_example",
      "name": "Harbor",
      "author": "You",

      "_help_appearance": "Either \"appearance\": \"dark\" or \"light\" with one \"colors\" block, as here, or \"dark\" and \"light\" blocks to follow your Mac's setting. Any color you leave out keeps Zeus's own. Colors are #RRGGBB, or #RRGGBBAA for see-through.",
      "appearance": "dark",
      "colors": {
        "_help": "Text needs 4.5:1 contrast against what it sits on, and controls 3:1; Settings shows \"Low contrast\" when a color misses that.",
        "panel": "#13232F",
        "outline": "#060D12",
        "frame": "#D7E7EF",
        "text": "#EAF4F8",
        "secondaryText": "#9CB6C3",
        "title": "#FFB86B",
        "accent": "#FFB86B",
        "onAccent": "#2A1600",
        "secondaryFill": "#24404F",
        "onSecondary": "#EAF4F8",
        "destructive": "#FF8A8A",
        "onDestructive": "#2A0606",
        "field": "#0B1820",
        "fieldBorder": "#4F7385",
        "track": "#1D3442",
        "fill": "#6FD3C1",
        "agentBubble": "#1A2F3D",
        "userBubble": "#2C4F63",
        "onUserBubble": "#F2F8FA",
        "focusRing": "#FFB86B",
        "positive": "#7FE0A0",
        "_help_link": "Links in messages, underlined. Optional: leave it out to use \"accent\". Set it when your accent is too pale to read as text.",
        "link": "#FFB86B",
        "_help_divider": "Optional hairline rules, such as the line under the status strip. Leave it out for secondaryText at 75%.",
        "_help_sessionColors": "The dots that tell your assistant's sessions apart: exactly 4 colors.",
        "sessionColors": ["#6FD3C1", "#FFB86B", "#B9A2FF", "#FF9FC2"]
      }
    }
    """#

    @discardableResult
    public static func write(into directory: URL) throws -> URL {
        try UserLibraryFolder.writeExample(json, as: fileName, into: directory)
    }
}
