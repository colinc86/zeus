import Foundation
import Testing
@testable import Zeus

@MainActor struct LM4TemplateTests {
    var root: URL {
        var url = URL(fileURLWithPath: #filePath); for _ in 0..<5 { url.deleteLastPathComponent() }; return url
    }
    @Test func currentTemplatesRequireMatchingVersionAndHash() throws {
        for name in ManagedTemplateSetup.names {
            let data = try Data(contentsOf: root.appendingPathComponent("Zeus/Resources/AssistantTemplate/" + name))
            #expect(String(decoding: data, as: UTF8.self).hasPrefix("<!-- zeus-template: \(ManagedTemplateHistory.version) -->\n"))
            #expect(ManagedTemplateSetup.hash(data) == ManagedTemplateHistory.versions[ManagedTemplateHistory.version]?[name], "Bump the template version and append hashes; do not replace a shipped entry")
        }
    }
    @Test func tableCoversEveryShippedTemplateInGit() async throws {
        let runner = FoundationProcessRunner()
        let path = "Zeus/Resources/AssistantTemplate/"
        for name in ManagedTemplateSetup.names {
            let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", root.path, "log", "--format=%H", "--", path + name], input: nil)
            #expect(result.status == 0)
            for commit in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
                let bytes = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", root.path, "show", String(commit) + ":" + path + name], input: nil)
                #expect(bytes.status == 0)
                #expect(ManagedTemplateSetup.isShipped(ManagedTemplateSetup.hash(bytes.stdout), name: name))
            }
        }
    }
    @Test func refreshPreservesEditsAndSymlinksAndRejectsStaleConfirmation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lm4-template-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resources = root.appendingPathComponent("Zeus/Resources/AssistantTemplate")
        let agents = folder.appendingPathComponent("AGENTS.md"), claude = folder.appendingPathComponent("CLAUDE.md")
        try Data("@AGENTS.md\n".utf8).write(to: claude)
        try Data("My instructions".utf8).write(to: agents)
        try ManagedTemplateSetup.refresh(folder: folder.path, resources: resources)
        #expect(try Data(contentsOf: claude) == Data(contentsOf: resources.appendingPathComponent("CLAUDE.md")))
        #expect(try String(contentsOf: agents, encoding: .utf8) == "My instructions")
        let snapshot = ManagedTemplateSetup.snapshot(folder: folder.path)
        #expect(ManagedTemplateSetup.edited(snapshot))
        try Data("New user edit".utf8).write(to: agents)
        #expect(throws: (any Error).self) { try ManagedTemplateSetup.refresh(folder: folder.path, resources: resources, confirmed: snapshot) }
        try ManagedTemplateSetup.refresh(folder: folder.path, resources: resources, confirmed: ManagedTemplateSetup.snapshot(folder: folder.path))
        #expect(try Data(contentsOf: agents) == Data(contentsOf: resources.appendingPathComponent("AGENTS.md")))
        try FileManager.default.removeItem(at: claude)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: agents)
        try ManagedTemplateSetup.refresh(folder: folder.path, resources: resources)
        #expect(try claude.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
    @Test func launchRecordsActualSetupAndOldLeaseIsStale() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        #expect(f.controller.record?.launchedToolsHash == ManagedTemplateSetup.toolsHash)
        #expect(f.controller.record?.launchedTemplateVersion == ManagedTemplateHistory.version)
        #expect(!f.controller.managedSetupStale.tools && !f.controller.managedSetupStale.template)
        var record = try #require(f.controller.record)
        record.launchedToolsHash = nil; record.launchedTemplateVersion = nil
        f.controller.shutdown(); try f.controller.store.save(record)
        // Re-created controller must not silently upgrade an adopted running lease's evidence.
        let other = try ManagedFixture(folder: f.folder)
        defer { other.controller.shutdown() }
        other.controller.activate(); try await other.settle()
        // A fresh fake host launches anew; actual launch updates the evidence.
        #expect(other.controller.record?.launchedToolsHash == ManagedTemplateSetup.toolsHash)
    }
}
