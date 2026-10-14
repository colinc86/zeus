import AppKit
import Testing
@testable import Zeus

@MainActor struct ConversationAutoScrollTests {
    @Test func shortMessagesAndTypingRowFollowTheBottom() {
        #expect(ConversationAutoScroll.targetOffset(viewport: .init(offset: 600, contentHeight: 1000, height: 300), newestMessageTop: 850, pinned: true) == 700)
        #expect(ConversationAutoScroll.targetOffset(viewport: .init(offset: 700, contentHeight: 1060, height: 300), newestMessageTop: 850, pinned: true) == 760)
        #expect(ConversationAutoScroll.targetOffset(viewport: .init(offset: 0, contentHeight: 80, height: 300), newestMessageTop: nil, pinned: true) == 0)
    }
    @Test func growingLongMessageStopsAtItsTop() {
        let targets = [950, 1100, 1300, 1800].map { height in
            ConversationAutoScroll.targetOffset(viewport: .init(offset: 500, contentHeight: CGFloat(height), height: 300), newestMessageTop: 800, pinned: true)
        }
        #expect(targets == [650, 800, 800, 800])
        #expect(ConversationAutoScroll.isPinned(viewport: .init(offset: 800, contentHeight: 1800, height: 300), newestMessageTop: 800))
        #expect(!ConversationAutoScroll.isPinned(viewport: .init(offset: 775, contentHeight: 1800, height: 300), newestMessageTop: 800))
    }
    @Test func historyReadersKeepTheirOffsetOnNewMessagesAndResizes() {
        for height in [300, 400] {
            #expect(ConversationAutoScroll.targetOffset(viewport: .init(offset: 200, contentHeight: 1800, height: CGFloat(height)), newestMessageTop: 1200, pinned: false) == 200)
        }
        #expect(!ConversationAutoScroll.isPinned(viewport: .init(offset: 200, contentHeight: 1800, height: 300), newestMessageTop: 1200))
        #expect(ConversationAutoScroll.targetOffset(viewport: .init(offset: 200, contentHeight: 1800, height: 300), newestMessageTop: 1200, pinned: true) == 1200)
    }
    @Test func bottomToleranceAndEmptyThreadsRemainPinned() {
        #expect(ConversationAutoScroll.isPinned(viewport: .init(offset: 676, contentHeight: 1000, height: 300), newestMessageTop: 850))
        #expect(!ConversationAutoScroll.isPinned(viewport: .init(offset: 675, contentHeight: 1000, height: 300), newestMessageTop: 850))
        #expect(ConversationAutoScroll.isPinned(viewport: .init(offset: 0, contentHeight: 100, height: 300), newestMessageTop: nil))
    }
    @Test func nativeOffsetsMatchForFlippedAndUnflippedDocuments() throws {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        for flipped in [false, true] {
            let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = flipped ? Flipped(frame: .init(x: 0, y: 0, width: 300, height: 1000)) : NSView(frame: .init(x: 0, y: 0, width: 300, height: 1000))
            let driver = ConversationScrollDriver(); driver.scrollView = scroll
            driver.scroll(to: 450)
            #expect(try #require(driver.viewport).offset == 450)
            driver.scroll(to: 9999)
            #expect(try #require(driver.viewport).offset == 800)
            driver.scroll(to: -10)
            #expect(try #require(driver.viewport).offset == 0)
        }
    }
}
