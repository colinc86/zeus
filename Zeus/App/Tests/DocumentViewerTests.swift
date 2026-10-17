import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class DocumentMessages: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}
@MainActor @Suite(.serialized) struct DocumentViewerTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-dv1-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func file(_ name: String, in root: URL, text: String = "Document") throws -> ZeusProtocol.Attachment {
        let url = root.appendingPathComponent(name); try text.write(to: url, atomically: true, encoding: .utf8)
        return .init(kind: .file, label: name, target: url.path)
    }
    private func settled(_ viewer: DocumentViewerModel, revision: Int = 0) async throws {
        let deadline = Date().addingTimeInterval(4)
        while viewer.revision <= revision && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(viewer.revision > revision)
    }
    @Test func openBackStepFolderAndLocalLinks() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try file("first.md", in: root), second = try file("second.txt", in: root)
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        #expect(viewer.open(first, siblings: [first, second], sourceCardID: "card", context: "Summary"))
        try await settled(viewer)
        #expect(viewer.current?.content?.renderer == .markdown)
        #expect(viewer.returnTarget == .init(entryID: "card:card", controlID: "open:\(first.id)"))
        #expect(viewer.navigate(root)); #expect(viewer.pages.count == 2)
        #expect(viewer.navigate(URL(fileURLWithPath: second.target)))
        #expect(!viewer.back() && viewer.current?.url.path == root.resolvingSymlinksInPath().path)
        #expect(!viewer.back() && viewer.current?.attachment.id == first.id)
        #expect(viewer.step(1) && viewer.current?.attachment.id == second.id)
        #expect(!viewer.step(1)); #expect(viewer.step(-1))
        viewer.expanded = true
        #expect(viewer.back() && !viewer.isOpen && viewer.expanded)
    }
    @Test func renderingSafetyAndCappedLoading() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let script = try file("pretend.txt", in: root, text: "#!/bin/sh\necho unsafe")
        #expect(DocumentLoader.load(URL(fileURLWithPath: script.target)).renderer == .revealOnly)
        let viewer = DocumentViewerModel()
        #expect(!viewer.open(script))
        #expect(!viewer.open(.init(kind: .url, label: "Web", target: "https://example.com")))
        let text = try file("large.txt", in: root, text: String(repeating: "a", count: 100))
        let content = DocumentLoader.load(URL(fileURLWithPath: text.target), limit: 20)
        #expect(content.text == String(repeating: "a", count: 20) && content.truncated)
        for (name, expected) in [("file.md", DocumentRenderer.markdown), ("file.swift", .text), ("file.pdf", .pdf), ("file.docx", .quickLook), ("file.csv", .quickLook), ("file.html", .quickLook)] {
            let value = try file(name, in: root)
            #expect(DocumentLoader.renderer(for: URL(fileURLWithPath: value.target)) == expected)
        }
        #expect(DocumentLoader.renderer(for: root) == .folder)
        #expect(DocumentLoader.renderer(for: root.appendingPathComponent("missing.txt")) == .missing)
        #expect(DocumentLoader.localImage("https://example.com/private.png", document: root.appendingPathComponent("doc.md")) == nil)
        let image = try file("local.png", in: root)
        #expect(DocumentLoader.localImage("local.png", document: root.appendingPathComponent("doc.md"))?.path == image.target)
        #expect(DocumentLoader.localImage("../outside.png", document: root.appendingPathComponent("doc.md")) == nil)
    }
    @Test func atomicStablePathRefreshPreservesPageAndScrollBookmark() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try file("live.md", in: root, text: "Before")
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        #expect(viewer.open(attachment)); try await settled(viewer)
        let page = try #require(viewer.current); let revision = viewer.revision
        viewer.offsets[page.id] = CGPoint(x: 0, y: 240)
        try "After the assistant edited this file".write(to: page.url, atomically: true, encoding: .utf8)
        try await settled(viewer, revision: revision)
        #expect(viewer.current?.id == page.id)
        #expect(viewer.current?.content?.text == "After the assistant edited this file")
        #expect(viewer.offsets[page.id]?.y == 240 && viewer.updatedAt != nil)
    }
    @Test func quoteAndAskPreserveDraftAndAttachOnce() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try file("notes.md", in: root)
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        #expect(viewer.open(attachment))
        let conversation = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: DocumentMessages())
        conversation.draft = "My existing thought"
        viewer.ask(in: conversation); viewer.selectedText = "First line\nSecond line"; viewer.quote(in: conversation)
        #expect(conversation.draft == "My existing thought\n\n> First line\n> Second line\n\n")
        #expect(conversation.draftAttachments.map(\.target) == [attachment.target])
    }
}
