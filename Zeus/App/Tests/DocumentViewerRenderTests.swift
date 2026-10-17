import AppKit
import PDFKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class DocumentRenderMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}
private struct DocumentRenderFixture: View {
    let viewer: DocumentViewerModel
    let conversation: ConversationModel
    let height: CGFloat
    @FocusState private var focus: Bool
    var body: some View {
        VStack(spacing: 8) {
            DocumentViewerView(model: viewer, conversation: conversation, back: {}, context: {}).frame(height: height)
            ZeusStatusStrip(.idle())
            ContextDraftAttachments(model: conversation, managed: false, workInFolder: { _ in })
            ZeusComposer(text: Binding(get: { conversation.draft }, set: { conversation.draft = $0 }), placeholder: "Ask about \(viewer.current?.attachment.label ?? "this")…",
                hasAttachments: !conversation.draftAttachments.isEmpty, focus: $focus, onClearReply: {}, onSend: {})
        }.zeusDialog()
    }
}

@MainActor @Suite(.serialized) struct DocumentViewerRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DV1_RENDERS"] == "1", "Opt-in native viewer render matrix."))
    func renderDocumentMatrix() async throws {
        var tree = URL(fileURLWithPath: #filePath); for _ in 0..<4 { tree.deleteLastPathComponent() }
        let output = tree.appendingPathComponent("build/dv1-renders")
        let root = tree.appendingPathComponent("build/dv1-fixtures/\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = """
        # Launch notes

        The smaller rollout keeps **recovery simple**. Review the trade-offs before approving the launch.

        ## Checklist
        - [x] Confirm the recovery path
        - [ ] Review the customer message

        | Choice | Result |
        | --- | --- |
        | Small rollout | Easy recovery |
        | Full release | More reach |

        ```swift
        let rollout = Release(scope: .small)
        rollout.verify()
        ```

        > Keep the first step reversible.

        [Read the implementation](Example.swift)
        """
        try markdown.write(to: root.appendingPathComponent("Launch.md"), atomically: true, encoding: .utf8)
        try "struct Release {\n    let scope: String\n    func verify() {\n        print(\"Ready to review\")\n    }\n}\n".write(to: root.appendingPathComponent("Example.swift"), atomically: true, encoding: .utf8)
        try ("A long document\n\nThe beginning stays readable. Open the file in its app for the rest.\n" + String(repeating: "x", count: DocumentLoader.textLimit + 1)).write(to: root.appendingPathComponent("Large.txt"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("Archive.zeusunknown"))
        let image = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { rect in
            NSColor(calibratedRed: 0.15, green: 0.3, blue: 0.45, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedRed: 0.8, green: 0.6, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 80, y: 100, width: 250, height: 300)).fill()
            NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 400, y: 180, width: 300, height: 100)).fill()
            return true
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("Sketch.png"))
        let pdf = PDFDocument(); if let page = PDFPage(image: image) { pdf.insert(page, at: 0) }
        #expect(pdf.write(to: root.appendingPathComponent("Plan.pdf")))
        try makeWord(at: root.appendingPathComponent("Brief.docx"), in: root)
        let states = ["md", "md-source", "text", "image", "pdf", "quicklook", "folder", "missing", "too-large", "unsupported", "find", "quote"]
        for state in states where ProcessInfo.processInfo.environment["DV1_RENDER_STATES"].map({ $0.split(separator: ",").contains(Substring(state)) }) ?? true {
            let filename: String = switch state {
            case "text": "Example.swift"
            case "image": "Sketch.png"
            case "pdf": "Plan.pdf"
            case "quicklook": "Brief.docx"
            case "missing": "Missing.md"
            case "too-large": "Large.txt"
            case "unsupported": "Archive.zeusunknown"
            default: "Launch.md"
            }
            for expanded in [false, true] { for scheme in [ColorScheme.light, .dark] { for font in ZeusFontChoice.allCases {
                let viewer = DocumentViewerModel()
                let conversation = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: DocumentRenderMessaging())
                let url = state == "folder" ? root : root.appendingPathComponent(filename)
                #expect(viewer.open(.init(kind: state == "folder" ? .folder : .file, label: state == "folder" ? "Launch documents" : filename, target: url.path), context: "Here's the draft. Review the recovery plan before launch."))
                let deadline = Date().addingTimeInterval(4)
                while viewer.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                viewer.expanded = expanded
                if state == "md-source" { viewer.toggleSource() }
                if state == "find" { viewer.findVisible = true; viewer.findText = "recovery" }
                if state == "quote" { viewer.selectedText = "Keep the first step reversible."; viewer.quote(in: conversation) }
                let width: CGFloat = expanded ? 760 : 380
                let view = DocumentRenderFixture(viewer: viewer, conversation: conversation, height: expanded ? 680 : 500)
                    .frame(width: width).environment(\.colorScheme, scheme).environment(\.zeusFontChoice, font)
                    .environment(\.zeusAnimationsActive, false).background(ZeusPalette.for(scheme).panel)
                let host = TestHostingView(rootView: view)
                let size = host.fittingSize
                let window = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
                for _ in 0..<(state == "quicklook" ? 30 : 5) { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
                let name = "dv1-\(state)-\(expanded ? "expanded" : "chat")-classic-\(scheme == .light ? "light" : "dark")-\(font.rawValue).png"
                try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
                window.contentView = nil; window.close(); viewer.close()
            } } }
        }
    }
    private func makeWord(at destination: URL, in root: URL) throws {
        let folder = root.appendingPathComponent("word-fixture")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("word"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.write(to: folder.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """.write(to: folder.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Launch brief</w:t></w:r></w:p><w:p><w:r><w:t>Review the recovery plan before approving the launch.</w:t></w:r></w:p></w:body></w:document>
        """.write(to: folder.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", destination.path, "."]; process.currentDirectoryURL = folder
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
    }
}
