import AppKit
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor @Suite(.serialized) struct DocumentNativeViewerTests {
    @Test func atomicReplacementRefreshesVisibleTextAndKeepsScroll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-dv1-native-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stable.txt")
        let before = (0..<300).map { "Before line \($0)" }.joined(separator: "\n")
        try before.write(to: url, atomically: true, encoding: .utf8)
        let model = DocumentViewerModel(); defer { model.close() }
        #expect(model.open(.init(kind: .file, label: "Stable", target: url.path)))
        try await wait(model, after: 0)
        let page = try #require(model.current)
        let native = DocumentTextScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        native.update(NSAttributedString(string: try #require(page.content?.text), attributes: [.font: font]), pageID: page.id, revision: model.revision, source: true, saved: nil)
        native.contentView.scroll(to: CGPoint(x: 0, y: 600)); native.reflectScrolledClipView(native.contentView)
        native.textView.setSelectedRange(NSRange(location: 4, length: 6))
        let fraction = native.contentView.bounds.minY / (native.textView.frame.height - native.contentSize.height)
        let revision = model.revision
        let after = (0..<400).map { "After  line \($0)" }.joined(separator: "\n")
        try after.write(to: url, atomically: true, encoding: .utf8)
        try await wait(model, after: revision)
        native.update(NSAttributedString(string: try #require(model.current?.content?.text), attributes: [.font: font]), pageID: page.id, revision: model.revision, source: true, saved: nil)
        #expect(native.textView.string == after)
        #expect(model.current?.id == page.id)
        #expect(native.textView.selectedRange() == NSRange(location: 4, length: 6))
        let updatedFraction = native.contentView.bounds.minY / (native.textView.frame.height - native.contentSize.height)
        #expect(abs(updatedFraction - fraction) < 0.01)
        #expect(native.contentView.bounds.minY > 0)
    }
    @Test func renderedMarkdownRefreshAndSourceToggleKeepTheNativeReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-dv1-markdown-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stable.md")
        let body = "# Heading\n\n" + (0..<100).map { "Paragraph **\($0)** with [local](next.md)." }.joined(separator: "\n\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        let model = DocumentViewerModel(); defer { model.close() }
        #expect(model.open(.init(kind: .file, label: "stable.md", target: url.path)))
        try await wait(model, after: 0)
        let native = DocumentTextScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        func render() throws {
            let page = try #require(model.current)
            native.update(DocumentTextStyling.make(page, revision: model.revision, choice: .system, scale: .default, palette: .light, width: 340), pageID: page.id, revision: model.revision, source: page.source, saved: nil)
        }
        try render()
        #expect(!native.textView.string.contains("# Heading") && !native.textView.string.contains("**"))
        #expect(native.textView.string.contains("Heading"))
        native.contentView.scroll(to: CGPoint(x: 0, y: 500)); native.reflectScrolledClipView(native.contentView)
        let revision = model.revision
        try body.replacingOccurrences(of: "Heading", with: "Revised").write(to: url, atomically: true, encoding: .utf8)
        try await wait(model, after: revision); try render()
        #expect(native.textView.string.contains("Revised") && native.contentView.bounds.minY > 450)
        let offset = native.contentView.bounds.minY
        model.toggleSource(); try render()
        #expect(native.textView.string.contains("# Revised") && native.textView.string.contains("**"))
        #expect(abs(native.contentView.bounds.minY - offset) < 2)
        model.toggleSource(); try render()
        #expect(!native.textView.string.contains("# Revised"))
        #expect(abs(native.contentView.bounds.minY - offset) < 2)
    }

    @Test(arguments: [false, true])
    func anchorsScrollNativeHeadingWithoutChangingSamePageState(source: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-fx6-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("Plan.md"), second = root.appendingPathComponent("Notes.md")
        let padding = String(repeating: "A paragraph in the document.\n\n", count: 45)
        let text = "# Start\n\n[Overview](#overview)\n\n" + padding + "## Overview\n\n" + padding + "## Overview\n\n" + padding
        try text.write(to: first, atomically: true, encoding: .utf8)
        try text.write(to: second, atomically: true, encoding: .utf8)
        let model = DocumentViewerModel(); defer { model.close() }
        #expect(model.open(.init(kind: .file, label: "Plan", target: first.path)))
        try await wait(model, after: 0)
        if source { model.toggleSource() }
        let native = DocumentTextScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        let coordinator = DocumentTextHost.Coordinator(model: model, url: first)
        func render() throws {
            let page = try #require(model.current)
            native.update(DocumentTextStyling.make(page, revision: model.revision, choice: .system, scale: .default, palette: .light, width: 340), pageID: page.id, revision: model.revision, source: page.source, saved: nil)
            native.scrollToAnchor(model.anchorRequest)
        }
        func click(_ link: String) {
            #expect(coordinator.textView(native.textView, clickedOnLink: link, at: 0))
        }
        func headingAtTop(_ slug: String) throws {
            let storage = try #require(native.textView.textStorage)
            var target: NSRange?
            storage.enumerateAttribute(DocumentTextStyling.anchorKey, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value as? String == slug { target = range; stop.pointee = true }
            }
            let range = try #require(target)
            let layout = try #require(native.textView.layoutManager), container = try #require(native.textView.textContainer)
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            #expect(abs(native.contentView.bounds.minY - rect.minY - native.textView.textContainerOrigin.y) < 1)
            #expect(native.contentView.bounds.minY > 500)
        }
        try render()
        var links: [String] = []
        native.textView.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: native.textView.string.utf16.count)) { value, _, _ in
            if let url = value as? URL { links.append(url.absoluteString) }
        }
        #expect(links.contains("#overview"))
        let pageID = model.current?.id
        model.findVisible = true; model.findText = "paragraph"
        native.textView.setSelectedRange(NSRange(location: 1, length: 3))
        click("#overview"); try render(); try headingAtTop("overview")
        #expect(model.pages.count == 1 && model.current?.id == pageID)
        #expect(model.findVisible && model.findText == "paragraph")
        #expect(native.textView.selectedRange() == NSRange(location: 1, length: 3))
        click("Plan.md"); try render()
        #expect(model.pages.count == 1 && model.current?.id == pageID)
        click("Plan.md#overview-1"); try render(); try headingAtTop("overview-1")
        #expect(model.pages.count == 1 && model.current?.id == pageID)
        let offset = native.contentView.bounds.origin
        click("#unknown"); try render()
        #expect(native.contentView.bounds.origin == offset && model.pages.count == 1)
        click("mailto:test@example.invalid"); click("custom:noop")
        #expect(model.pages.count == 1)
        let revision = model.revision
        click("Notes.md#overview"); try await wait(model, after: revision); try render(); try headingAtTop("overview")
        #expect(model.pages.count == 2 && model.current?.url.lastPathComponent == "Notes.md")
        #expect(!model.back() && model.current?.id == pageID)
        #expect(model.back() && !model.isOpen)
    }

    @Test(arguments: [false, true])
    func headingSlugsUseVisibleWordsAndUniqueSuffixes(source: Bool) {
        var page = DocumentViewerModel.Page(attachment: .init(kind: .file, label: "Plan", target: "/synthetic/Plan.md"), sourceCardID: nil, context: nil)
        page.content = .init(renderer: .markdown, text: "# Hello, **World**!\n\n# Hello, World!\n\n# Hello World-1\n\n# Café plan\n\n# Café plan")
        page.source = source
        let text = DocumentTextStyling.make(page, revision: 1, choice: .system, scale: .default, palette: .light, width: 340)
        var slugs: [String] = []
        text.enumerateAttribute(DocumentTextStyling.anchorKey, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let slug = value as? String { slugs.append(slug) }
        }
        #expect(slugs == ["hello-world", "hello-world-1", "hello-world-1-1", "café-plan", "café-plan-1"])
    }

    @Test func imagesFitWithoutUpscalingAndRecenterAfterHeightChanges() {
        let view = DocumentImageScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        let image = NSImageView(); image.imageScaling = .scaleProportionallyDown
        image.image = NSImage(size: NSSize(width: 100, height: 80))
        view.documentView = image; view.naturalSize = image.image!.size
        view.fitImage()
        #expect(image.frame.width == view.contentSize.width)
        #expect(image.frame.height == view.contentSize.height)
        #expect(view.magnification == 1)
        view.setFrameSize(NSSize(width: 380, height: 600)); view.layout()
        #expect(image.frame.height == view.contentSize.height)
        view.naturalSize = NSSize(width: 1000, height: 2000); view.fitImage()
        #expect(abs(image.frame.height - view.contentSize.width * 2) < 1)
    }

    private func wait(_ model: DocumentViewerModel, after revision: Int) async throws {
        let deadline = Date().addingTimeInterval(4)
        while model.revision <= revision && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.revision > revision)
    }
}
