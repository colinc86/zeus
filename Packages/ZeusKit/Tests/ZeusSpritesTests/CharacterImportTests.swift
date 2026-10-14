import Foundation
import Testing
@testable import ZeusSprites

// C1: importing characters, plain-words validation, and the example file.

private func character(id: String, name: String = "Blob", rows: [String] = ["k"], extra: String = "") -> String {
    let rowList = rows.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
    { "id": "\(id)", "name": "\(name)", "size": [4, 4],
      "canvas": { "size": [8, 8], "origin": [0, 0], "anchor": [4, 8] },
      "palette": { "k": "#000000" }, "layers": { "a": { "rows": [\(rowList)] } },
      "animations": { "idle": { "fps": 1, "frames": [["a"]] }\(extra) } }
    """
}

private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-c1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct PlainWordsTests {
    @Test func rowWidthNamesTheRowAndTheExpectedWidth() throws {
        let issues = SpriteCharacter.load(data: Data(character(id: "x", rows: ["kkkk", "kkkk", "kkk"]).utf8), source: "x.json").issues
        let issue = try #require(issues.first { $0.severity == .error })
        #expect(issue.message.contains("different lengths"), "the CLI wording keeps its old keyword")
        #expect(issue.plainMessage == "Layer \"a\": row 3 is 3 pixels wide; every row must be 4.")
    }

    @Test func framesAndAnimationsReadAsWords() {
        func plain(_ message: String) -> String { SpriteIssue(severity: .error, source: "x.json", message: message).plainMessage }
        #expect(plain("animations.working.frames[2]: unknown layer \"arm\"") == "Frame 3 of \"working\": there's no layer named \"arm\".")
        #expect(plain("animations.idle.frames[0].hold must be ≥ 1") == "Frame 1 of \"idle\": hold must be ≥ 1.")
        #expect(plain("animations.idle is required") == "The \"idle\" animation is required.")
        #expect(plain("animations.talking.fps must be in (0, 60]") == "The \"talking\" animation: fps must be in (0, 60].")
        #expect(plain("animations.idle.base: unknown layer \"x\"") == "The \"idle\" animation's base layers: there's no layer named \"x\".")
        #expect(plain("animations.happy.accents[1].duration must be > 0 and ≤ every[0]") == "Accent 2 of \"happy\": duration must be > 0 and ≤ every[0].")
        #expect(plain("palettes.glow: key \"q\" isn't in the base palette") == "Palette \"glow\": key \"q\" isn't in the base palette.")
        #expect(plain("particles.sparks.life must be > 0") == "Particles \"sparks\": life must be > 0.")
    }

    @Test func jsonSyntaxErrorsSayWhichLine() throws {
        let broken = "{\n  \"id\": \"x\"\n  \"name\": \"X\"\n}"
        let issue = try #require(SpriteCharacter.load(data: Data(broken.utf8), source: "x.json").issues.first)
        #expect(issue.message.hasPrefix("invalid character JSON"))
        #expect(issue.plainMessage.hasPrefix("This file isn't valid JSON:"))
        #expect(issue.plainMessage.contains("line 3") && issue.plainMessage.hasSuffix("Check for a missing comma or quote just before it."), "\(issue.plainMessage)")
        let truncated = try #require(SpriteCharacter.load(data: Data("{\n\"id\": \"x\",\n".utf8), source: "x.json").issues.first)
        #expect(truncated.plainMessage.hasPrefix("This file isn't valid JSON:") && truncated.plainMessage.contains("line"), "\(truncated.plainMessage)")
        let missing = try #require(SpriteCharacter.load(data: Data(#"{ "id": "x" }"#.utf8), source: "x.json").issues.first)
        #expect(missing.plainMessage.hasPrefix("This file is missing"), "\(missing.plainMessage)")
    }
}

@Suite struct ReservedIDTests {
    @Test func underscoreIDsAreSkippedSilently() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(character(id: "_draft").utf8).write(to: dir.appendingPathComponent("draft.json"))
        // Even a broken file is skipped when its id is reserved: it's a note, not a character.
        try Data(#"{ "id": "_notes", "anything": true }"#.utf8).write(to: dir.appendingPathComponent("notes.json"))
        try Data(character(id: "mine").utf8).write(to: dir.appendingPathComponent("mine.json"))
        let library = CharacterLibrary.load(userDirectory: dir)
        #expect(library.character(id: "_draft") == nil)
        #expect(library.character(id: "mine") != nil)
        // The test character's tiny canvas earns it a warning; the reserved files add nothing.
        #expect(library.problems.allSatisfy { $0.source == "mine.json" && $0.severity == .warning }, "\(library.problems)")
    }

    @Test func exampleIsSkippedButValidOnceRenamed() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try CharacterExample.write(into: dir)
        #expect(url.lastPathComponent == "Example Character.json")
        let before = CharacterLibrary.load(userDirectory: dir)
        #expect(!before.characters.contains { $0.name == "Pip" } && before.problems.isEmpty)
        // The user's edits are never overwritten.
        try Data("edited".utf8).write(to: url)
        try CharacterExample.write(into: dir)
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited")
        // Renamed, it loads with no errors and no warnings, and draws every state it defines.
        let renamed = CharacterExample.json.replacingOccurrences(of: #""id": "_example""#, with: #""id": "pip""#)
        let (pip, issues) = SpriteCharacter.load(data: Data(renamed.utf8), source: "pip.json")
        #expect(issues.isEmpty, "\(issues)")
        let loaded = try #require(pip)
        #expect(loaded.definedStates.contains(.idle) && loaded.definedStates.contains(.talking))
        for state in loaded.definedStates { _ = SpriteRenderer.render(loaded, state: state, time: 0.5) }
    }
}

@Suite struct CharacterImportTests {
    let builtIn = CharacterLibrary.load(userDirectory: nil).characters

    @Test func newCharacterGoesInUnderItsID() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try CharacterImport.plan(data: Data(character(id: "blob").utf8), source: "Downloaded.json", userDirectory: dir, builtIn: builtIn).get()
        #expect(plan.fileName == "blob.json" && plan.conflict == nil && !plan.alreadyInstalled)
        let url = try CharacterImport.install(plan, into: dir)
        #expect(try Data(contentsOf: url) == Data(character(id: "blob").utf8), "copied byte for byte")
        #expect(CharacterImport.doneMessage(plan) == "Added Blob.")
        #expect(CharacterLibrary.load(userDirectory: dir).character(id: "blob") != nil)
    }

    @Test func builtInIDAsksFirst() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try CharacterImport.plan(data: Data(character(id: "zeus", name: "My Zeus").utf8), source: "z.json", userDirectory: dir, builtIn: builtIn).get()
        #expect(plan.conflict == .builtIn(name: "Zeus"))
        #expect(CharacterImport.replacePrompt(try #require(plan.conflict)) == "Replace the built-in Zeus?")
    }

    @Test func sameIDAsYoursReplacesThatFileAndAsks() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(character(id: "blob", name: "Old Blob").utf8).write(to: dir.appendingPathComponent("My Blob.json"))
        let update = Data(character(id: "blob", name: "New Blob", rows: ["kk"]).utf8)
        let plan = try CharacterImport.plan(data: update, source: "blob.json", userDirectory: dir, builtIn: builtIn).get()
        #expect(plan.fileName == "My Blob.json")
        #expect(plan.conflict == .yours(name: "Old Blob", fileName: "My Blob.json"))
        #expect(CharacterImport.replacePrompt(try #require(plan.conflict)) == "Replace your Old Blob?")
        // Importing the exact same file again: nothing to ask, nothing to copy.
        let again = try CharacterImport.plan(data: Data(character(id: "blob", name: "Old Blob").utf8), source: "My Blob.json", userDirectory: dir, builtIn: builtIn).get()
        #expect(again.alreadyInstalled && again.conflict == nil && CharacterImport.doneMessage(again) == "Old Blob is already added.")
    }

    @Test func aFileNameTakenByAnotherCharacterGetsANumber() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(character(id: "other").utf8).write(to: dir.appendingPathComponent("blob.json"))
        let plan = try CharacterImport.plan(data: Data(character(id: "blob").utf8), source: "b.json", userDirectory: dir, builtIn: builtIn).get()
        #expect(plan.fileName == "blob 2.json")
    }

    @Test func invalidFilesSayWhatIsWrongAndCopyNothing() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bad = Data(character(id: "blob", rows: ["kk", "k"]).utf8)
        guard case .failure(let failure) = CharacterImport.plan(data: bad, source: "b.json", userDirectory: dir, builtIn: builtIn) else {
            Issue.record("expected a failure"); return
        }
        #expect(failure.lines == ["Layer \"a\": row 2 is 1 pixel wide; every row must be 2."])
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
    }

    @Test func reservedIDsCantBeImported() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let result = CharacterImport.plan(data: Data(CharacterExample.json.utf8), source: CharacterExample.fileName, userDirectory: dir, builtIn: builtIn)
        guard case .failure(.reservedID("_example")) = result else { Issue.record("expected reservedID, got \(result)"); return }
        #expect(CharacterImport.Failure.reservedID("_example").lines.first?.contains("starts with _") == true)
    }
}
