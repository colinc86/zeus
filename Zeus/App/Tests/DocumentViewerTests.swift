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
        viewer.threadBookmark = .init(entryID: "old", relativeTop: 20, firstEntryID: "old", width: 380)
        viewer.threadOffset = 500; viewer.fromPeek = true
        #expect(viewer.open(first))
        #expect(viewer.threadBookmark == nil && viewer.threadOffset == nil && !viewer.fromPeek)
    }
    @Test func fragmentsStayOnTheCurrentPageAndSurviveResolution() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try file("first.md", in: root, text: "# Overview\n\nText")
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        #expect(viewer.open(first)); try await settled(viewer)
        let page = try #require(viewer.current)
        let local = try #require(DocumentLoader.localLink("#overview", document: page.url))
        #expect(local.fragment == "overview")
        #expect(viewer.navigate(local))
        #expect(viewer.pages.count == 1)
        #expect(viewer.current?.id == page.id)
        #expect(DocumentLoader.localLink("next.md#part", document: page.url)?.fragment == "part")
    }
    @Test func steppingCountsOnlyViewableSiblings() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let md = try file("plan.md", in: root), script = try file("run.sh", in: root), pdf = try file("plan.pdf", in: root)
        let missing = ZeusProtocol.Attachment(kind: .file, label: "Missing", target: root.appendingPathComponent("missing.md").path)
        let invalid = ZeusProtocol.Attachment(kind: .file, label: "Invalid", target: "relative.md")
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        #expect(viewer.open(md, siblings: [md, script]))
        #expect(viewer.attachmentPosition == nil && !viewer.canNext)
        #expect(viewer.open(md, siblings: [md, script, missing, invalid, pdf]))
        #expect(viewer.attachmentPosition == "1/2")
        #expect(viewer.step(1))
        #expect(viewer.current?.attachment.id == pdf.id && viewer.attachmentPosition == "2/2")
        #expect(viewer.step(-1) && viewer.current?.attachment.id == md.id)
        try FileManager.default.removeItem(atPath: pdf.target)
        #expect(viewer.attachmentPosition == "1/2") // The open session retains its sibling positions.
        #expect(viewer.open(md, siblings: [md, script, missing, invalid, pdf]))
        #expect(viewer.attachmentPosition == nil)
        let folder = ZeusProtocol.Attachment(kind: .folder, label: "Folder", target: root.path)
        #expect(viewer.open(md, siblings: [md, folder]))
        #expect(viewer.step(1) && viewer.current?.attachment.id == folder.id)
    }
    @Test func folderMetadataUsesShortDatesAndReadableKinds() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 8, minute: 2)))
        #expect(DocumentLoader.modifiedLabel(now, now: now, calendar: calendar) == "Today 8:02")
        #expect(DocumentLoader.modifiedLabel(now.addingTimeInterval(-86400), now: now, calendar: calendar) == "Yesterday")
        #expect(DocumentLoader.modifiedLabel(now.addingTimeInterval(-4 * 86400), now: now, calendar: calendar) == "12 Oct")
        #expect(DocumentLoader.folderKind(isFolder: true, description: nil, extension: "") == "Folder")
        #expect(DocumentLoader.folderKind(isFolder: false, description: nil, extension: "swift") == "SWIFT")
        #expect(DocumentLoader.folderKind(isFolder: false, description: "text", extension: "txt") == "Text")
        #expect(DocumentLoader.folderKind(isFolder: false, description: nil, extension: "") == "Document")
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
    @Test func typingAttachesOnceRemovalSticksAndQuoteIsTrimmedAndCapped() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try file("notes.md", in: root)
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        #expect(viewer.open(attachment))
        let conversation = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: DocumentMessages())
        conversation.draft = "A"; viewer.typed(in: conversation)
        #expect(conversation.draftAttachments.count == 1)
        conversation.draftAttachments = []; conversation.draft = "Another character"; viewer.typed(in: conversation)
        #expect(conversation.draftAttachments.isEmpty)
        viewer.ask(in: conversation)
        #expect(conversation.draftAttachments.count == 1)
        conversation.draft = ""
        viewer.selectedText = "   " + String(repeating: "a", count: 2_050) + "   "
        viewer.quote(in: conversation)
        #expect(conversation.draft == "> " + String(repeating: "a", count: 2_000) + "…\n\n")
    }

    @Test func automaticChipsFollowDraftButExplicitChipsSurvive() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try file("draft.md", in: root)
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        let conversation = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: DocumentMessages())
        #expect(viewer.open(attachment))
        viewer.selectedText = "Quoted passage"; viewer.quote(in: conversation)
        #expect(conversation.draftAttachments.count == 1)
        conversation.draft = " \n\n"; viewer.typed(in: conversation)
        #expect(conversation.draftAttachments.isEmpty)
        conversation.draft = "Again"; viewer.typed(in: conversation)
        #expect(conversation.draftAttachments.count == 1)
        viewer.back(); viewer.removeEmptyAutomaticAttachments(in: conversation)
        #expect(conversation.draftAttachments.count == 1)
        conversation.draft = ""; viewer.removeEmptyAutomaticAttachments(in: conversation)
        #expect(conversation.draftAttachments.isEmpty)
        #expect(viewer.open(attachment))
        conversation.draft = "Again"; viewer.typed(in: conversation)
        #expect(viewer.navigate(URL(fileURLWithPath: attachment.target)))
        viewer.ask(in: conversation) // Explicit Ask promotes the same-path automatic chip.
        conversation.draft = ""
        viewer.typed(in: conversation); viewer.back(); viewer.removeEmptyAutomaticAttachments(in: conversation)
        #expect(conversation.draftAttachments.count == 1)
    }
    @Test func removingAutomaticChipThenClearingAndTypingDoesNotReattach() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try file("draft.md", in: root)
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        let conversation = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: DocumentMessages())
        #expect(viewer.open(attachment))
        conversation.draft = "A"; viewer.typed(in: conversation)
        conversation.draftAttachments.removeAll { $0.id == attachment.id }
        conversation.draft = ""; viewer.typed(in: conversation)
        conversation.draft = "B"; viewer.typed(in: conversation)
        #expect(conversation.draftAttachments.isEmpty)
    }

    @Test func watchesInPlaceWritesAndRearmsAfterReplacementAndReappearance() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try file("watched.txt", in: root, text: "Initial")
        let viewer = DocumentViewerModel(); defer { viewer.close() }
        #expect(viewer.open(attachment)); try await settled(viewer)
        let url = try #require(viewer.current?.url)
        for (text, atomic) in [("In place", false), ("Atomic replacement", true), ("New inode in place", false)] {
            let revision = viewer.revision
            try text.write(to: url, atomically: atomic, encoding: .utf8)
            try await settled(viewer, revision: revision)
            #expect(viewer.current?.content?.text == text)
        }
        var revision = viewer.revision
        try FileManager.default.removeItem(at: url); try await settled(viewer, revision: revision)
        #expect(viewer.current?.content?.renderer == .missing)
        revision = viewer.revision
        try "Restored".write(to: url, atomically: true, encoding: .utf8); try await settled(viewer, revision: revision)
        #expect(viewer.current?.content?.text == "Restored")
    }

}
