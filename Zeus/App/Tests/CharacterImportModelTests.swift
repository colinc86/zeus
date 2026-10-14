import Foundation
import Testing
import ZeusSprites
@testable import Zeus

// C1: Settings › Character import, live reload and problem listing. Every test uses its own temporary Characters
// folder and UserDefaults suite; nothing touches the user's real folder.

@MainActor private final class CharacterFixture {
    let suite = "zeus-c1-\(UUID())"
    let defaults: UserDefaults
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-c1-\(UUID())/Characters", isDirectory: true)
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-c1-src-\(UUID())", isDirectory: true)
    let settings: AppSettings
    let model: LibraryImportModel

    init() {
        defaults = UserDefaults(suiteName: suite) ?? .standard
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        settings = AppSettings(defaults: defaults, userDirectory: directory)
        model = .characters(settings)
    }

    func cleanup() {
        settings.stopWatchingUserFolders()
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: source)
        defaults.removePersistentDomain(forName: suite)
    }

    /// A character file outside the Characters folder, as if downloaded.
    @discardableResult func file(_ name: String, id: String, displayName: String = "Blob", rows: [String] = ["kk"]) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(Self.json(id: id, name: displayName, rows: rows).utf8).write(to: url)
        return url
    }

    static func json(id: String, name: String, rows: [String] = ["kk"]) -> String {
        let list = rows.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        { "id": "\(id)", "name": "\(name)", "size": [4, 4],
          "canvas": { "size": [12, 20], "origin": [4, 14], "anchor": [6, 18] },
          "palette": { "k": "#000000" }, "layers": { "a": { "rows": [\(list)] } },
          "animations": { "idle": { "fps": 1, "frames": [["a"]] } } }
        """
    }
}

@MainActor @Suite(.serialized) struct CharacterImportModelTests {
    @Test func importAddsSelectsAndSaysSo() throws {
        let f = CharacterFixture(); defer { f.cleanup() }
        f.model.importFile(at: try f.file("Downloaded Blob.json", id: "blob"))
        #expect(f.model.notice == .added("Added Blob.", notes: []))
        #expect(f.settings.currentCharacterID == "blob" && f.settings.currentCharacter?.name == "Blob")
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("blob.json").path))
    }

    @Test func builtInIDWaitsForReplaceAndCancelCopiesNothing() throws {
        let f = CharacterFixture(); defer { f.cleanup() }
        let url = try f.file("zeus.json", id: "zeus", displayName: "My Zeus")
        f.model.importFile(at: url)
        #expect(f.model.replacePrompt == "Replace the built-in Zeus?" && f.model.notice == nil)
        f.model.cancelReplace()
        #expect(f.model.replacePrompt == nil)
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("zeus.json").path))
        #expect(f.settings.currentCharacter?.name == "Zeus")

        f.model.importFile(at: url)
        f.model.confirmReplace()
        #expect(f.model.notice == .added("Added My Zeus.", notes: []))
        #expect(f.settings.currentCharacterID == "zeus" && f.settings.currentCharacter?.name == "My Zeus")
    }

    @Test func invalidFileSaysWhatIsWrong() throws {
        let f = CharacterFixture(); defer { f.cleanup() }
        f.model.importFile(at: try f.file("Broken.json", id: "broken", rows: ["kkk", "kk"]))
        #expect(f.model.notice == .failed(file: "Broken.json", lines: ["Layer \"a\": row 2 is 2 pixels wide; every row must be 3."]))
        #expect(f.settings.currentCharacterID == "zeus")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: f.directory.path))?.isEmpty ?? true)
    }

    @Test func exampleAndFolderAreCreatedAndTheExampleNeverLoads() throws {
        let f = CharacterFixture(); defer { f.cleanup() }
        let folder = try #require(try f.model.folder())
        #expect(folder == f.directory && FileManager.default.fileExists(atPath: folder.path))
        let example = try #require(try f.model.exampleFile())
        #expect(example.lastPathComponent == "Example Character.json")
        f.settings.reloadCharacters()
        #expect(!f.settings.availableCharacters.contains { $0.name == "Pip" })
        #expect(f.settings.characterProblems.isEmpty)
    }
}

@MainActor @Suite(.serialized) struct CharacterReloadTests {
    @Test func editedCurrentRerendersRemovedFallsBackAndReturns() throws {
        let f = CharacterFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let url = f.directory.appendingPathComponent("blob.json")
        try Data(CharacterFixture.json(id: "blob", name: "Blob").utf8).write(to: url)
        f.settings.reloadCharacters()
        f.settings.currentCharacterID = "blob"
        let before = try #require(f.settings.currentCharacter?.fingerprint)

        // Unchanged: the same character values stay (the avatar keeps playing).
        let zeus = try #require(f.settings.availableCharacters.first { $0.id == "zeus" }?.fingerprint)
        f.settings.reloadCharacters()
        #expect(f.settings.currentCharacter?.fingerprint == before)

        // Edited in place: new art under the same id.
        try Data(CharacterFixture.json(id: "blob", name: "Blob Two", rows: ["k"]).utf8).write(to: url)
        f.settings.reloadCharacters()
        #expect(f.settings.currentCharacterID == "blob" && f.settings.currentCharacter?.name == "Blob Two")
        #expect(f.settings.currentCharacter?.fingerprint != before)
        #expect(f.settings.availableCharacters.first { $0.id == "zeus" }?.fingerprint == zeus)

        // Removed: falls back to Zeus, but the choice is remembered for when the file returns.
        try FileManager.default.removeItem(at: url)
        f.settings.reloadCharacters()
        #expect(f.settings.currentCharacterID == "zeus")
        try Data(CharacterFixture.json(id: "blob", name: "Blob").utf8).write(to: url)
        f.settings.reloadCharacters()
        #expect(f.settings.currentCharacterID == "blob")
    }

    @Test func invalidFilesAreListedInPlainWords() throws {
        let f = CharacterFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        try Data("{\n  \"id\": \"x\"\n  \"name\": \"X\"\n}".utf8).write(to: f.directory.appendingPathComponent("typo.json"))
        f.settings.reloadCharacters()
        let lines = f.settings.characterProblemLines
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.isError && line.text.hasPrefix("typo.json wasn't loaded. This file isn't valid JSON:") && line.text.contains("line 3"), "\(line.text)")
    }

    @Test func watcherReloadsWhenAFileChanges() async throws {
        let f = CharacterFixture(); defer { f.cleanup() }
        f.settings.startWatchingUserFolders()
        #expect(FileManager.default.fileExists(atPath: f.directory.path), "the folder is created to watch it")
        try Data(CharacterFixture.json(id: "blob", name: "Watched Blob").utf8).write(to: f.directory.appendingPathComponent("blob.json"))
        let deadline = Date().addingTimeInterval(10)
        while !f.settings.availableCharacters.contains(where: { $0.id == "blob" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(f.settings.availableCharacters.contains { $0.name == "Watched Blob" })
    }

    @Test func watcherDebouncesABurst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-c1-watch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reloads = 0
        let watcher = FolderWatcher(directory: dir) { reloads += 1 }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        for i in 0..<5 { try Data("\(i)".utf8).write(to: dir.appendingPathComponent("f\(i).json")) }
        let deadline = Date().addingTimeInterval(10)
        while reloads == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(800))
        #expect(watcher.changeCount >= 1)
        #expect(reloads == 1, "five quick writes reload once, got \(reloads)")
    }
}
