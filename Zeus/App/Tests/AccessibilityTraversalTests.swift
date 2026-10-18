import AppKit
import Testing
@testable import Zeus

@MainActor struct AccessibilityTraversalTests {
    @Test func publicTreeDoesNotIncludeIgnoredBackingViews() {
        let root = NSView(), backing = NSView(), exposed = NSView()
        root.addSubview(backing)
        root.setAccessibilityChildren([exposed])
        exposed.setAccessibilityRole(.button)
        exposed.setAccessibilityLabel("Public action")
        let nodes = jumpAXNodes(root)
        #expect(nodes.contains { $0 === exposed })
        #expect(!nodes.contains { $0 === backing })
        #expect(exposed.accessibilityLabel() == "Public action")
    }

    @Test func duplicateAndCyclicChildrenAreVisitedOnce() {
        let root = NSView(), child = NSView()
        root.setAccessibilityChildren([child, child])
        child.setAccessibilityChildren([root])
        #expect(jumpAXNodes(root).count == 2)
        child.setAccessibilityChildren([]); root.setAccessibilityChildren([])
    }
}
