import AppKit
import Testing
@testable import Zeus

@MainActor struct ConversationScrollingTests {
    private func route(_ key: UInt16, command: Bool = false, other: Bool = false, focused: Bool = true,
                       empty: Bool = false, first: Bool = false, last: Bool = false) -> ConversationScrollCommand? {
        ConversationScrollPolicy.command(keyCode: key, command: command, otherModifiers: other, composerFocused: focused,
                                         empty: empty, firstLine: first, lastLine: last)
    }
    @Test func arrowsRespectEditingBoundariesAndModifiers() {
        #expect(route(126) == nil && route(125) == nil)
        #expect(route(126, empty: true) == .line(-1))
        #expect(route(125, empty: true) == .line(1))
        #expect(route(126, first: true) == .line(-1))
        #expect(route(125, first: true) == nil)
        #expect(route(125, last: true) == .line(1))
        #expect(route(126, last: true) == nil)
        #expect(route(126, focused: false) == .line(-1))
        #expect(route(125, other: true, empty: true) == nil)
        #expect(route(126, command: true) == .oldest)
        #expect(route(125, command: true) == .latest)
        #expect(route(116, other: true) == .page(-1))
        #expect(route(121) == .page(1))
        #expect(route(123, empty: true) == nil) // Left remains caret editing.
    }
    @Test func caretBoundariesUseVisualWrapAndTheTrailingEmptyLine() {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 400))
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.string = "one two three four five six seven eight nine ten\nlast line\n"
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let first = ConversationScrollPolicy.caretLines(in: editor)
        #expect(first.first && !first.last)
        editor.setSelectedRange(NSRange(location: 24, length: 0))
        let middle = ConversationScrollPolicy.caretLines(in: editor)
        #expect(!middle.first && !middle.last)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let last = ConversationScrollPolicy.caretLines(in: editor)
        #expect(!last.first && last.last)
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        let selected = ConversationScrollPolicy.caretLines(in: editor)
        #expect(!selected.first && !selected.last)
    }
    @Test func nativeDriverMovesByDistanceAndClampsToBothEnds() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        driver.perform(.line(1))
        #expect(scroll.contentView.bounds.minY == 40)
        driver.perform(.page(1))
        #expect(scroll.contentView.bounds.minY > 200)
        driver.perform(.oldest)
        #expect(scroll.contentView.bounds.minY == 0)
        driver.perform(.line(-1))
        #expect(scroll.contentView.bounds.minY == 0)
        driver.perform(.latest)
        #expect(scroll.contentView.bounds.maxY == 1000)
        driver.perform(.page(1))
        #expect(scroll.contentView.bounds.maxY == 1000)
    }
    @Test func retainedFollowRequestRetriesWhenNativeDocumentHeightChanges() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        driver.scroll(to: 800)
        // SwiftUI knows about the next row before TestHostingView's document has grown.
        driver.followLatest(newestMessageTop: 950)
        for _ in 0..<10 { await Task.yield() }
        #expect(scroll.contentView.bounds.minY == 800)
        document.setFrameSize(NSSize(width: 300, height: 1150))
        for _ in 0..<10 { await Task.yield() }
        #expect(scroll.contentView.bounds.minY == 950)
        driver.stopFollowing()
        document.setFrameSize(NSSize(width: 300, height: 1300))
        for _ in 0..<10 { await Task.yield() }
        #expect(scroll.contentView.bounds.minY == 950)
    }

    @Test func restorationWaitsForLayoutAndYieldsToNavigation() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scroll.documentView = document
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        var completed = 0
        driver.restore(to: 700) { completed += 1 }
        for _ in 0..<10 { await Task.yield() }
        #expect(completed == 0)
        document.setFrameSize(NSSize(width: 300, height: 1200))
        for _ in 0..<10 { await Task.yield() }
        #expect(driver.viewport?.offset == 700 && completed == 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 0)) // A later native layout/focus adjustment.
        for _ in 0..<10 { await Task.yield() }
        #expect(driver.viewport?.offset == 700 && completed == 1)
        driver.perform(.line(-1))
        document.setFrameSize(NSSize(width: 300, height: 1400))
        for _ in 0..<10 { await Task.yield() }
        #expect(driver.viewport?.offset == 660 && !driver.isRestoring)
    }

}
