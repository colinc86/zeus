import Foundation

// Importing a character file into the user's Characters folder (Settings › Character › Import Character…), the
// plain-words form of validation problems that Settings shows, and the example file it can write.

extension SpriteIssue {
    /// The message in plain words, for people rather than the CLI: JSON paths become "frame 3 of "working"",
    /// "layer "body"" and so on. It starts with a capital letter and ends with a period.
    public var plainMessage: String { SpritePlainWords.sentence(message) }
}

enum SpritePlainWords {
    static func sentence(_ message: String) -> String {
        var text = message
        // frame N of "state" (1-based), with an optional field: animations.working.frames[2].hold → frame 3 of "working": hold
        text = replace(#"animations\.([A-Za-z]+)\.frames\[(\d+)\](?:\.([A-Za-z]+))?"#, in: text) { g in
            "frame \((Int(g[2]) ?? 0) + 1) of \"\(g[1])\"" + (g[3].isEmpty ? "" : ": \(g[3])")
        }
        text = replace(#"animations\.([A-Za-z]+)\.accents\[(\d+)\](?:\.([A-Za-z]+))?"#, in: text) { g in
            "accent \((Int(g[2]) ?? 0) + 1) of \"\(g[1])\"" + (g[3].isEmpty ? "" : ": \(g[3])")
        }
        text = replace(#"animations\.([A-Za-z]+)\.(base|over)"#, in: text) { g in "the \"\(g[1])\" animation's \(g[2]) layers" }
        text = replace(#"animations\.([A-Za-z]+)\.([A-Za-z.]+)"#, in: text) { g in "the \"\(g[1])\" animation: \(g[2])" }
        text = replace(#"animations\.([A-Za-z]+)"#, in: text) { g in "the \"\(g[1])\" animation" }
        text = replace(#"palettes\.([^\s:.]+)(?:\.([^\s:]+))?"#, in: text) { g in "palette \"\(g[1])\"" + (g[2].isEmpty ? "" : ", key \(g[2])") }
        text = replace(#"layers\.([^\s:.]+)"#, in: text) { g in "layer \"\(g[1])\"" }
        text = replace(#"particles\.([^\s:.]+)(?:\.([A-Za-z]+))?"#, in: text) { g in "particles \"\(g[1])\"" + (g[2].isEmpty ? "" : ": \(g[2])") }
        text = text.replacingOccurrences(of: ": unknown layer ", with: ": there's no layer named ")
        text = text.replacingOccurrences(of: ": unknown palette ", with: ": there's no palette named ")
        text = text.replacingOccurrences(of: " (rows have different lengths)", with: "")
        text = text.replacingOccurrences(of: "invalid character JSON: syntax error: ", with: "This file isn't valid JSON: ")
        text = text.replacingOccurrences(of: "invalid character JSON: missing ", with: "This file is missing ")
        text = text.replacingOccurrences(of: "invalid character JSON: ", with: "This file doesn't match the character format: ")
        guard let first = text.first else { return text }
        text = first.uppercased() + text.dropFirst()
        if let last = text.last, !".?!".contains(last) { text += "." }
        // The usual cause of an unexpected character in JSON is a missing comma at the end of the line before.
        if text.hasPrefix("This file isn't valid JSON: Unexpected character") {
            text = text.replacingOccurrences(of: "JSON: Unexpected", with: "JSON: unexpected")
                + " Check for a missing comma or quote just before it."
        }
        return text
    }

    /// Replaces every match of `pattern`; `make` gets the capture groups (index 0 is the whole match, missing ones are "").
    private static func replace(_ pattern: String, in text: String, _ make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += make(groups)
            cursor = match.range.location + match.range.length
        }
        return out + ns.substring(from: cursor)
    }
}

/// Validates a character file and works out where it goes in the user's Characters folder, before anything is copied.
public enum CharacterImport {
    /// An existing character the import would replace. The app asks first.
    public enum Conflict: Equatable, Sendable {
        /// Same `id` as a built-in character: the import overrides it (the built-in file is never touched).
        case builtIn(name: String)
        /// Same `id` as a character already in the Characters folder: the import overwrites that file.
        case yours(name: String, fileName: String)
    }

    /// A file that passed validation, ready to install.
    public struct Plan: Sendable {
        public let character: SpriteCharacter
        /// The name it gets in the Characters folder.
        public let fileName: String
        public let conflict: Conflict?
        /// Problems that don't stop it loading, in plain words.
        public let warnings: [SpriteIssue]
        /// The exact file is already installed: nothing to copy, just select it.
        public let alreadyInstalled: Bool
        let data: Data
    }

    /// Why a file can't be imported. Each case reads as plain words via `lines`.
    public enum Failure: Error, Equatable, Sendable {
        /// Validation errors, with where they are when known.
        case invalid([SpriteIssue])
        /// The `id` starts with `_`, which is reserved for examples.
        case reservedID(String)

        /// What's wrong, one plain sentence per line.
        public var lines: [String] {
            switch self {
            case .invalid(let issues): issues.filter { $0.severity == .error }.map(\.plainMessage)
            case .reservedID(let id):
                ["Its id \"\(id)\" starts with _, which Zeus keeps for examples. Change \"id\" to a name of your own, using letters, digits, - and _."]
            }
        }
    }

    /// Validates `data` with the real loader and plans where it goes.
    /// - Parameters:
    ///   - source: the file's name, used in messages.
    ///   - userDirectory: the Characters folder (it may not exist yet).
    ///   - builtIn: the bundled characters, to spot an `id` that would replace one.
    public static func plan(data: Data, source: String, userDirectory: URL, builtIn: [SpriteCharacter]) -> Result<Plan, Failure> {
        if let id = CharacterLibrary.declaredID(in: data), CharacterLibrary.isReservedID(id) { return .failure(.reservedID(id)) }
        let (loaded, issues) = SpriteCharacter.load(data: data, source: source)
        guard let character = loaded else { return .failure(.invalid(issues)) }
        let warnings = issues.filter { $0.severity == .warning }

        let existing = userFiles(in: userDirectory)
        if let mine = existing.first(where: { $0.id == character.id }) {
            let same = (try? Data(contentsOf: userDirectory.appendingPathComponent(mine.fileName))) == data
            return .success(Plan(character: character, fileName: mine.fileName, conflict: same ? nil : .yours(name: mine.name, fileName: mine.fileName),
                                 warnings: warnings, alreadyInstalled: same, data: data))
        }
        let conflict = builtIn.first { $0.id == character.id }.map { Conflict.builtIn(name: $0.name) }
        let taken = Set(existing.map { $0.fileName.lowercased() })
        var fileName = "\(character.id).json"
        var n = 2
        while taken.contains(fileName.lowercased()) || FileManager.default.fileExists(atPath: userDirectory.appendingPathComponent(fileName).path) {
            fileName = "\(character.id) \(n).json"
            n += 1
        }
        return .success(Plan(character: character, fileName: fileName, conflict: conflict, warnings: warnings, alreadyInstalled: false, data: data))
    }

    /// Copies the planned file into `userDirectory` (creating it), byte for byte. Returns where it went.
    @discardableResult
    public static func install(_ plan: Plan, into userDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let url = userDirectory.appendingPathComponent(plan.fileName)
        if !plan.alreadyInstalled { try plan.data.write(to: url, options: .atomic) }
        return url
    }

    /// The question to ask before replacing, e.g. "Replace the built-in Zeus?".
    public static func replacePrompt(_ conflict: Conflict) -> String {
        switch conflict {
        case .builtIn(let name): "Replace the built-in \(name)?"
        case .yours(let name, _): "Replace your \(name)?"
        }
    }

    /// What Settings says after a successful import.
    public static func doneMessage(_ plan: Plan) -> String {
        plan.alreadyInstalled ? "\(plan.character.name) is already added." : "Added \(plan.character.name)."
    }

    /// The characters in `directory` by declared id (unreadable files and reserved ids are left out).
    static func userFiles(in directory: URL) -> [(fileName: String, id: String, name: String)] {
        struct Peek: Decodable { var id: String?; var name: String? }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let peek = try? JSONDecoder().decode(Peek.self, from: data),
                  let id = peek.id, !CharacterLibrary.isReservedID(id) else { return nil }
            return (url.lastPathComponent, id, peek.name ?? id)
        }
    }
}

/// A small, working example character with notes on every part, written by Settings › Character › Open Example.
/// JSON has no comments, so the notes are `"_help"` strings the loader ignores; its `"_example"` id keeps it out of
/// the roster until the user gives it an id of their own.
public enum CharacterExample {
    /// The file name in the Characters folder.
    public static let fileName = "Example Character.json"

    /// The example's text.
    public static let json = #"""
    {
      "_help": "An example character. Zeus skips it because its id starts with _. To make your own: save a copy of this file in this folder with a new name, change \"id\" below, and it appears in Settings › Character. Zeus reloads the folder whenever a file changes, so you can edit and watch. Full reference: docs/design/SPRITE_FORMAT.md in the Zeus repository.",
      "format": 1,
      "id": "_example",
      "name": "Pip",
      "summary": "A small green blob. Edit me!",

      "_help_size": "size is the art box in pixels, [width, height]. Layers are placed inside it: (0, 0) is its top-left corner.",
      "size": [12, 10],
      "preferredScale": 6,

      "canvas": {
        "_help": "The canvas is the image Zeus draws into; it never changes size. Leave room above the art for emotes (the … and ! glyphs) and for motion. origin is where the art box's top-left sits in the canvas. anchor is the point between the character's feet, which stays fixed on screen.",
        "size": [16, 26],
        "origin": [2, 14],
        "anchor": [8, 24]
      },

      "_help_palette": "palette maps one character to a color: #rrggbb, or #rrggbbaa for see-through. In layer rows, . (dot) and space are transparent.",
      "palette": {
        "k": "#1b1b2f",
        "b": "#5fd37a",
        "B": "#3fa35a",
        "w": "#ffffff",
        "m": "#c0392b"
      },

      "_help_layers": "Layers are pieces of art. Every row of a layer must be the same width. x and y place a layer in the art box, so small layers (eyes, a blink, a mouth) only store the pixels they change and are painted on top.",
      "layers": {
        "body": {
          "_help": "The whole blob, 12 × 10.",
          "rows": [
            "....kkkk....",
            "..kkbbbbkk..",
            ".kbbbbbbbbk.",
            ".kbbbbbbbbk.",
            "kbbbbbbbbbbk",
            "kbbbbbbbbbbk",
            "kbbbbbbbbbbk",
            "kBbbbbbbbbBk",
            "kBBBbbbbBBBk",
            ".kkkkkkkkkk."
          ]
        },
        "eyes": { "_help": "Open eyes, placed at x 3, y 4.", "x": 3, "y": 4, "rows": ["kw..kw", "kk..kk"] },
        "blink": { "_help": "Paints body color over the eyes, so they look shut.", "x": 3, "y": 4, "rows": ["bb..bb", "kk..kk"] },
        "mouth": { "x": 5, "y": 7, "rows": ["mm"] },
        "mouthOpen": { "x": 5, "y": 7, "rows": ["mm", "mm"] }
      },

      "_help_animations": "One animation per state: idle (required), talking, thinking, working, alert, waiting, happy, sleeping. A state you leave out uses a close one (working → thinking → idle; waiting → alert → idle; the rest → idle). fps is ticks per second; each frame lists the layers drawn on top of base, and hold keeps a frame for that many ticks.",
      "animations": {
        "idle": {
          "_help": "Eyes open for 10 ticks, then one blink.",
          "fps": 4,
          "base": ["body", "eyes", "mouth"],
          "frames": [
            { "layers": [], "hold": 10 },
            ["blink"]
          ]
        },
        "talking": {
          "_help": "The mouth opens and closes while Zeus types a message.",
          "fps": 6,
          "base": ["body", "eyes"],
          "frames": [["mouth"], ["mouthOpen"]]
        },
        "happy": {
          "_help": "motion moves the whole character: float, bob, hop, sway or shake.",
          "fps": 4,
          "base": ["body", "eyes", "mouthOpen"],
          "motion": { "type": "hop", "amplitude": 2, "period": 0.5 },
          "frames": [[]]
        }
      }
    }
    """#

    /// Writes the example into `directory` (creating it) unless it's already there, and returns its location.
    /// An existing example is never overwritten: it may hold the user's edits.
    @discardableResult
    public static func write(into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) { try Data(json.utf8).write(to: url, options: .atomic) }
        return url
    }
}
