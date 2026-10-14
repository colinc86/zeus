import AppKit
import SwiftUI
import ZeusDesign

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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if resizeHandle.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ConversationResizeHandle: NSView {
    var edge: ConversationWidth.Edge = .left
    var onResize: ((CGFloat, ConversationWidth.Edge) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    var focusColor: NSColor = .keyboardFocusIndicatorColor { didSet { if oldValue != focusColor { needsDisplay = true } } }
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var startEdge: ConversationWidth.Edge = .left
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self else { return }
        focusColor.setFill()
        NSRect(x: edge == .left ? 1 : bounds.width - 2, y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    func beginDrag(at x: CGFloat, width: CGFloat) { startX = x; startWidth = width; startEdge = edge }
    func drag(to x: CGFloat) { onResize?(ConversationWidth.dragged(startWidth: startWidth, delta: x - startX, edge: startEdge), startEdge) }
    override func mouseDown(with event: NSEvent) { beginDrag(at: NSEvent.mouseLocation.x, width: window?.frame.width ?? bounds.width) }
    override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation.x) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard event.type == .keyDown, modifiers == [.command, .option], onResize != nil else { return false }
        switch event.keyCode {
        case 123: return nudge(-20)
        case 124: return nudge(20)
        default: return false
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
            if event.keyCode == 123, nudge(-20) { return }
            if event.keyCode == 124, nudge(20) { return }
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Reset width", action: #selector(resetWidth), keyEquivalent: "")
        item.target = self; item.isEnabled = onReset != nil; menu.addItem(item)
        return menu
    }
    @objc private func resetWidth() { onReset?() }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { "Conversation width" }
    override func accessibilityHelp() -> String? { "Drag, or press Command Option Left or Right Arrow to resize. Use Reset width to restore the default." }
    override func accessibilityValue() -> Any? { window.map { NSNumber(value: Double($0.frame.width.rounded())) } }
    override func accessibilityValueDescription() -> String? { window.map { "\(Int($0.frame.width.rounded())) points" } }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard onReset != nil else { return nil }
        return [NSAccessibilityCustomAction(name: "Reset width", handler: { [weak self] in
            guard let reset = self?.onReset else { return false }
            reset(); return true
        })]
    }
    override func accessibilityPerformIncrement() -> Bool {
        nudge(20)
    }
    override func accessibilityPerformDecrement() -> Bool {
        nudge(-20)
    }
    private func nudge(_ delta: CGFloat) -> Bool {
        guard let onResize, let window else { return false }
        onResize(window.frame.width + delta, edge); onEnd?()
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }
}

/// Keeps the native edge's focus ring in the SwiftUI theme, including live theme/appearance edits.
struct ConversationResizeColor: NSViewRepresentable {
    let color: NSColor
    func makeNSView(context: Context) -> ColorView { ColorView() }
    func updateNSView(_ view: ColorView, context: Context) { view.color = color; view.apply() }
    final class ColorView: NSView {
        var color: NSColor = .clear
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let host = view as? ConversationHostingView { host.resizeHandle.focusColor = color; return }
                ancestor = view.superview
            }
        }
    }
}
