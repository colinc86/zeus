import Foundation

/// The characters available to the app: bundled ones plus any in the user's directory.
/// A user file with the same `id` as a bundled character overrides it.
public struct CharacterLibrary: Sendable {
    /// The id of the default character.
    public static let defaultCharacterID = "zeus"

    /// The bundled roster in display order.
    public static let bundledOrder = ["zeus", "ghost", "pumpkin", "robot", "hero", "wizard",
                                      "cat", "skeleton", "slime", "bat", "owl", "mushroom"]

    /// All loaded characters: the bundled roster in `bundledOrder` (a user override keeps its slot),
    /// then other user characters by name.
    public private(set) var characters: [SpriteCharacter]

    /// Validation problems found while loading (non-fatal: bad files are skipped), as one line each.
    public var issues: [String] { problems.map(\.description) }

    /// Validation problems found while loading, for showing in plain words (`SpriteIssue.plainMessage`).
    public private(set) var problems: [SpriteIssue]

    /// Ids starting with `_` are reserved for examples and notes (`Example Character.json`): the loader skips them.
    public static func isReservedID(_ id: String) -> Bool { id.hasPrefix("_") }

    /// The directory of bundled character JSON files.
    public static var bundledDirectory: URL? {
        Bundle.module.url(forResource: "Characters", withExtension: nil)
    }

    /// Loads the bundled characters, then the user's (if `userDirectory` is given and exists).
    public static func load(userDirectory: URL?) -> CharacterLibrary {
        var byID: [String: SpriteCharacter] = [:]
        var issues: [SpriteIssue] = []
        for directory in [bundledDirectory, userDirectory].compactMap(\.self) {
            let (characters, found) = loadDirectory(directory)
            issues += found
            for character in characters { byID[character.id] = character }
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
        return CharacterLibrary(characters: sorted, problems: issues)
    }

    /// Loads every `*.json` file in `directory` (non-recursive), in filename order.
    /// Returns the characters that loaded and every issue found. A missing directory is not an issue.
    public static func loadDirectory(_ directory: URL) -> (characters: [SpriteCharacter], issues: [SpriteIssue]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var characters: [SpriteCharacter] = []
        var issues: [SpriteIssue] = []
        var seen: [String: String] = [:]
        for url in files.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                issues.append(SpriteIssue(severity: .error, source: url.lastPathComponent, message: "can't read file: \(error.localizedDescription)"))
                continue
            }
            if let id = declaredID(in: data), isReservedID(id) { continue }
            let (character, found) = SpriteCharacter.load(data: data, source: url.lastPathComponent)
            issues += found
            guard let character else { continue }
            if let other = seen[character.id] {
                issues.append(SpriteIssue(severity: .warning, source: url.lastPathComponent, message: "id \"\(character.id)\" is also defined in \(other); this file wins"))
                characters.removeAll { $0.id == character.id }
            }
            seen[character.id] = url.lastPathComponent
            characters.append(character)
        }
        return (characters, issues)
    }

    /// The `id` a file declares, read without validating the rest. Nil when it isn't JSON or has no string `id`.
    public static func declaredID(in data: Data) -> String? {
        struct Peek: Decodable { var id: String? }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.id
    }

    /// The character with `id`, if loaded.
    public func character(id: String) -> SpriteCharacter? {
        characters.first { $0.id == id }
    }
}
