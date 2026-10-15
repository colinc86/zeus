import AppKit
import SwiftUI
import Testing
@testable import Zeus

// A12b: the Settings tab bar names each tab as its AX title (what System Events and other processes read as `name`),
// marks the current tab selected, and pressing one through accessibility switches tabs. Offscreen window only.
@MainActor @Suite(.serialized) struct SettingsTabAccessibilityTests {
    private func nodes(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let kids = (((node as AnyObject).accessibilityChildren?() ?? nil) as? [NSObject] ?? []) + ((node as? NSView)?.subviews ?? [])
            return [node] + kids.flatMap(walk)
        }
        return walk(root)
    }

    @Test func tabsHaveTitlesSelectionAndPress() async throws {
        let navigation = SettingsNavigation()
        let host = NSHostingView(rootView: SettingsTabBar(navigation: navigation).frame(width: 640).environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 640, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }

        func title(_ n: NSObject) -> String { ((n as AnyObject).accessibilityTitle?() ?? nil) ?? "" }
        func selected(_ n: NSObject) -> Bool { (n as AnyObject).isAccessibilitySelected?() ?? false }
        func tabs() -> [NSObject] {
            nodes(host).filter { ((($0 as AnyObject).accessibilityRole?() ?? nil) == .button) && navigation.tabs.map(\.rawValue).contains(title($0)) }
        }
        #expect(tabs().map(title) == navigation.tabs.map(\.rawValue))
        #expect(tabs().filter(selected).map(title) == [navigation.tab.rawValue])

        let appearance = try #require(tabs().first { title($0) == SettingsTab.appearance.rawValue })
        #expect((appearance as AnyObject).accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(navigation.tab == .appearance)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(tabs().filter(selected).map(title) == ["Appearance"])
    }
}
