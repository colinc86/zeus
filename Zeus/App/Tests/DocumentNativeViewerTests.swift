import AppKit
import Testing
import ZeusProtocol
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
    private func wait(_ model: DocumentViewerModel, after revision: Int) async throws {
        let deadline = Date().addingTimeInterval(4)
        while model.revision <= revision && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.revision > revision)
    }
}
