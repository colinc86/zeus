import Foundation

/// A folder of user JSON files keyed by `id`, such as Characters and Themes: where an import goes, whether it replaces
/// one, and the example file. Shared by `CharacterImport` (ZeusSprites) and `ZeusThemeImport` (ZeusDesign).
public enum UserLibraryFolder {
    /// A file already in the folder.
    public struct Entry: Equatable, Sendable {
        public let fileName: String
        public let id: String
        public let name: String
    }

    /// Where an import goes.
    public struct Placement: Equatable, Sendable {
        /// The file name in the folder.
        public let fileName: String
        /// The user's file with the same `id`, which the import overwrites.
        public let replaces: Entry?
        /// That file already holds exactly these bytes: nothing to copy.
        public let alreadyInstalled: Bool
    }

    /// Ids starting with `_` are reserved for examples and notes: loaders skip them and imports refuse them.
    public static func isReservedID(_ id: String) -> Bool { id.hasPrefix("_") }

    /// The `id` a file declares, read without validating the rest. Nil when it isn't JSON or has no string `id`.
    public static func declaredID(in data: Data) -> String? { peek(data)?.id }

    /// The JSON files in `directory` with a usable `id`, by file name. Unreadable files and reserved ids are left out.
    public static func entries(in directory: URL) -> [Entry] {
        jsonFiles(in: directory).compactMap { url in
            guard let data = try? Data(contentsOf: url), let peek = peek(data), let id = peek.id, !isReservedID(id) else { return nil }
            return Entry(fileName: url.lastPathComponent, id: id, name: peek.name ?? id)
        }
    }

    /// The `*.json` files in `directory` (not recursive), sorted by name. A missing folder has none.
    public static func jsonFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Where a file with `id` and contents `data` goes: over the user's file with that id, else `<id>.json`
    /// (numbered when that name is taken by something else).
    public static func placement(id: String, data: Data, in directory: URL) -> Placement {
        let existing = entries(in: directory)
        if let mine = existing.first(where: { $0.id == id }) {
            let same = (try? Data(contentsOf: directory.appendingPathComponent(mine.fileName))) == data
            return Placement(fileName: mine.fileName, replaces: same ? nil : mine, alreadyInstalled: same)
        }
        var fileName = "\(id).json"
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) {
            fileName = "\(id) \(n).json"
            n += 1
        }
        return Placement(fileName: fileName, replaces: nil, alreadyInstalled: false)
    }

    /// Writes `data` as `fileName` in `directory` (creating it), byte for byte, unless it's already there.
    @discardableResult
    public static func install(_ data: Data, as fileName: String, into directory: URL, alreadyInstalled: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        if !alreadyInstalled { try data.write(to: url, options: .atomic) }
        return url
    }

    /// Writes an example file into `directory` (creating it) unless one is there: it may hold the user's edits.
    @discardableResult
    public static func writeExample(_ text: String, as fileName: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) { try Data(text.utf8).write(to: url, options: .atomic) }
        return url
    }

    private struct Peek: Decodable { var id: String?; var name: String? }
    private static func peek(_ data: Data) -> Peek? { try? JSONDecoder().decode(Peek.self, from: data) }
}
