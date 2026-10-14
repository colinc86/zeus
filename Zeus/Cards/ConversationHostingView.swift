import AppKit
import SwiftUI

/// A native edge target above the SwiftUI content; it never interferes with the
/// editor or scroll view except in the outermost six points of the away edge.
@MainActor
final class ConversationHostingView: NSHostingView<ConversationView> {
    let resizeHandle = ConversationResizeHandle()
    var resizeEdge: ConversationWidth.Edge = .left { didSet { needsLayout = true } }
    required init(rootView: ConversationView) {
        super.init(rootView: rootView)
        addSubview(resizeHandle)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        resizeHandle.edge = resizeEdge
        resizeHandle.frame = CGRect(x: resizeEdge == .left ? 0 : max(0, bounds.width - 6), y: 0, width: 6, height: bounds.height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if resizeHandle.frame.contains(point) { return resizeHandle }
        return super.hitTest(point)
    }
}

@MainActor
final class ConversationResizeHandle: NSView {
    var edge: ConversationWidth.Edge = .left
    var onResize: ((CGFloat, ConversationWidth.Edge) -> Void)?
    var onEnd: (() -> Void)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var startEdge: ConversationWidth.Edge = .left
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    func beginDrag(at x: CGFloat, width: CGFloat) { startX = x; startWidth = width; startEdge = edge }
    func drag(to x: CGFloat) { onResize?(ConversationWidth.dragged(startWidth: startWidth, delta: x - startX, edge: startEdge), startEdge) }
    override func mouseDown(with event: NSEvent) { beginDrag(at: NSEvent.mouseLocation.x, width: window?.frame.width ?? bounds.width) }
    override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation.x) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { "Conversation width" }
    override func accessibilityHelp() -> String? { "Drag to resize the conversation." }
    override func accessibilityPerformIncrement() -> Bool {
        guard let onResize, let window else { return false }
        onResize(window.frame.width + 20, edge); onEnd?(); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard let onResize, let window else { return false }
        onResize(window.frame.width - 20, edge); onEnd?(); return true
    }
}
