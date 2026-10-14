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

    /// Validation problems found while loading (non-fatal: bad files are skipped).
    public private(set) var issues: [String]

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
        return CharacterLibrary(characters: sorted, issues: issues.map(\.description))
    }

    /// Loads every `*.json` file in `directory` (non-recursive), in filename order.
    /// Returns the characters that loaded and every issue found. A missing directory is not an issue.
    public static func loadDirectory(_ directory: URL) -> (characters: [SpriteCharacter], issues: [SpriteIssue]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var characters: [SpriteCharacter] = []
        var issues: [SpriteIssue] = []
        var seen: [String: String] = [:]
        for url in files.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let (character, found) = SpriteCharacter.load(contentsOf: url)
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

    /// The character with `id`, if loaded.
    public func character(id: String) -> SpriteCharacter? {
        characters.first { $0.id == id }
    }
}
