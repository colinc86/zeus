import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private func selectableNodes(_ root: Any) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        func children(_ name: String, _ argument: String? = nil) -> [Any] {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return [] }
            return node.perform(selector, with: argument)?.takeUnretainedValue() as? [Any] ?? []
        }
        return [node] + (children("accessibilityChildren") + children("accessibilityAttributeValue:", "AXChildren")
            + children("accessibilityAttributeValue:", "AXContents") + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func selectableString(_ node: NSObject, _ name: String) -> String {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? (node.perform(selector)?.takeUnretainedValue() as? String ?? "") : ""
}

/// VoiceOver and other assistive apps turn on enhanced accessibility; labelled selectable text then recursed until the stack overflowed.
@Suite(.serialized) @MainActor struct SelectableTextAccessibilityTests {
    private func withEnhancedAccessibility<V: View>(_ view: V, _ body: (NSView) async throws -> Void) async throws {
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber
        NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { NSApp.perform(enhanced, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
        let host = TestHostingView(rootView: AnyView(view.frame(width: 600, height: 240, alignment: .topLeading).environment(\.accessibilityEnabled, true)))
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: 600, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        try await body(host)
    }

    @Test func messageBodyKeepsItsSpokenLabelAndLinks() async throws {
        let markdown = ZeusMarkdown.attributed("> Read [the docs](https://example.com) now", choice: .system, palette: .light)
        let view = MessageBodyView(markdown: markdown, active: false, enabled: false, soundEnabled: false, reveal: nil)
        try await withEnhancedAccessibility(view) { host in
            let nodes = selectableNodes(host)
            #expect(nodes.contains { selectableString($0, "accessibilityLabel") == view.accessibilityText })
            #expect(nodes.contains { selectableString($0, "accessibilityRole") == NSAccessibility.Role.link.rawValue })
        }
    }

    @Test func expandedNoticeDetailKeepsItsExactTextLabel() async throws {
        let notice = ThreadNotice(kind: .learning, createdAt: Date(), summary: "Sent your daily summary", actionTitle: "View", detail: "Fixture summary text.")
        try await withEnhancedAccessibility(ConversationNoticeLine(notice: notice, maxWidth: 560, hasAction: false, perform: {})) { host in
            let view = try #require(selectableNodes(host).first { selectableString($0, "accessibilityLabel") == "View: Sent your daily summary" })
            #expect((view as AnyObject).accessibilityPerformPress?() == true)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(selectableNodes(host).map { selectableString($0, "accessibilityLabel") }.contains("Exact text: Fixture summary text."))
        }
    }
}
