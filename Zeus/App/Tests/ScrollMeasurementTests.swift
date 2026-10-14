import AppKit
import Testing
@testable import Zeus

@MainActor private final class ScrollMeasurementPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var screen: NSScreen? { NSScreen.screens.first }
}

@MainActor @Suite("Scroll measurement event payload")
struct ScrollMeasurementTests {
    @Test func createsPrecisePhasedWheelEventWithLocalCoordinates() throws {
        let window = ScrollMeasurementPanel(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 600),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 30, width: 340, height: 520))
        window.contentView?.addSubview(scroll)
        let event = try #require(ScrollBenchmark.wheelEvent(scroll: scroll, delta: -24, phase: .changed))
        #expect(event.type == .scrollWheel)
        #expect(event.hasPreciseScrollingDeltas)
        #expect(event.scrollingDeltaY == -24)
        #expect(event.phase == .changed)
        #expect(event.modifierFlags.isEmpty)
        let point = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        #expect(abs(event.locationInWindow.x - point.x) < 0.1)
        #expect(abs(event.locationInWindow.y - point.y) < 0.1)
        #expect(!window.isKeyWindow && !window.isMainWindow)
        window.close()
    }
    @Test func detachedViewCannotCreateWindowInput() {
        let scroll = NSScrollView()
        #expect(ScrollBenchmark.wheelEvent(scroll: scroll, delta: -24, phase: .began) == nil)
        #expect(ScrollBenchmark.availability(of: scroll)["ready"] as? Bool == false)
    }
}
