import Foundation
import Testing
@testable import Zeus

@MainActor struct LearningFolderOwnershipTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fx5-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func export(_ path: String, text: String = "Zeus export", id: String = "item") -> LearningFolderFile {
        .init(path: path, data: Data(text.utf8), ids: [id])
    }
    @Test(arguments: ["all", "prune", "item"])
    func existingProjectFilesSurviveEveryDeletion(operation: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let userPaths = ["Zeus/App/Important.swift", "Zeus/README.md", "Zeus/days/2026-10-17/notes-mine.md"]
        for path in userPaths { try put("User work: " + path, at: project.appendingPathComponent(path)) }
        let disk = try LearningFolderDisk(stateURL: root.appendingPathComponent("manifest.json"))
        let owned = "Zeus/days/2026-10-17/focus.md"
        try disk.apply([export("Zeus/README.md"), export(owned)], root: project, token: disk.invalidate())
        #expect(disk.collisionPaths == ["Zeus/README.md"])
        #expect(disk.existing(project, path: "Zeus/README.md") == nil, "Never attach an unowned collision as learning evidence")
        switch operation {
        case "prune": try disk.prune(root: project, keeping: [], token: disk.invalidate())
        case "item": try disk.erase(root: project, ids: ["item"])
        default: try disk.erase(root: project, ids: nil)
        }
        for path in userPaths { #expect(try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) == "User work: " + path) }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(owned).path))
    }
    @Test func collisionRetriesAfterMoveAndReportsAllPaths() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LearningFolderDisk(stateURL: root.appendingPathComponent("manifest.json"))
        let paths = ["Zeus/README.md", "Zeus/rules.md", "Zeus/days/2026-10-17/focus.md"]
        for path in paths { try put("User work", at: root.appendingPathComponent(path)) }
        try disk.apply(paths.map { export($0) }, root: root, token: disk.invalidate())
        #expect(disk.collisionPaths.count == 3)
        #expect(LearningFolderWriter.collisionMessage(disk.collisionPaths) == "Zeus didn't replace Zeus/README.md and 2 other files because Zeus didn't write them. Move or rename them to let Zeus write there.")
        for path in paths { try FileManager.default.moveItem(at: root.appendingPathComponent(path), to: root.appendingPathComponent(path + ".mine")) }
        try disk.apply(paths.map { export($0) }, root: root, token: disk.invalidate())
        #expect(disk.collisionPaths.isEmpty)
        for path in paths { #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == "Zeus export") }
    }
    @Test func lostManifestAdoptsOnlyMatchingBytes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("manifest.json")
        let disk = try LearningFolderDisk(stateURL: state)
        try disk.apply([export("Zeus/README.md"), export("Zeus/rules.md")], root: root, token: disk.invalidate())
        try FileManager.default.removeItem(at: state)
        try put("User replacement", at: root.appendingPathComponent("Zeus/rules.md"))
        let restored = try LearningFolderDisk(stateURL: state)
        try restored.apply([export("Zeus/README.md"), export("Zeus/rules.md")], root: root, token: restored.invalidate())
        #expect(restored.collisionPaths == ["Zeus/rules.md"])
        #expect(restored.existing(root, path: "Zeus/README.md") != nil)
        try restored.erase(root: root, ids: nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Zeus/README.md").path))
        #expect(try String(contentsOf: root.appendingPathComponent("Zeus/rules.md"), encoding: .utf8) == "User replacement")
    }
    @Test func removesOnlyEmptyCreatedDirectoriesAndRecordedTemps() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("manifest.json")
        let disk = try LearningFolderDisk(stateURL: state)
        try disk.apply([export("Zeus/days/2026-10-17/focus.md")], root: root, token: disk.invalidate())
        let unknown = root.appendingPathComponent("Zeus/days/.zeus-write-user")
        try put("Not an owned temp", at: unknown)
        // Simulate interruption after the durable temporary-file registration, before rename.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        var folders = try #require(json["folders"] as? [String: [String: Any]])
        let key = root.standardizedFileURL.path
        let temp = "Zeus/days/2026-10-17/.zeus-write-" + UUID().uuidString
        folders[key]?["temporaryFiles"] = [temp]; json["folders"] = folders
        try JSONSerialization.data(withJSONObject: json).write(to: state)
        try put("Interrupted export", at: root.appendingPathComponent(temp))
        let recovered = try LearningFolderDisk(stateURL: state)
        try recovered.erase(root: root, ids: nil)
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Zeus/days/2026-10-17").path))
        try FileManager.default.removeItem(at: unknown)
        try recovered.erase(root: root, ids: nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Zeus").path))
    }
    @Test func exclusiveFirstWriteNeverReplacesAnExistingTarget() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("mine.md")
        try put("User work", at: target)
        #expect(throws: (any Error).self) { try LearningFolderDisk.atomic(Data("Export".utf8), at: target, replacing: false) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "User work")
    }
    @Test func legacyManifestAndReplacementDirectoryNeverClaimExtraFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("manifest.json")
        let disk = try LearningFolderDisk(stateURL: state)
        let path = "Zeus/README.md"
        try disk.apply([export(path)], root: root, token: disk.invalidate())
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        var folders = try #require(json["folders"] as? [String: [String: Any]])
        let key = root.standardizedFileURL.path
        folders[key]?.removeValue(forKey: "directories"); folders[key]?.removeValue(forKey: "temporaryFiles")
        json["folders"] = folders
        try JSONSerialization.data(withJSONObject: json).write(to: state)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        let userFile = root.appendingPathComponent(path + "/mine.txt")
        try put("User work", at: userFile)
        let legacy = try LearningFolderDisk(stateURL: state)
        #expect(throws: (any Error).self) { try legacy.erase(root: root, ids: nil) }
        #expect(try String(contentsOf: userFile, encoding: .utf8) == "User work")
    }
}
