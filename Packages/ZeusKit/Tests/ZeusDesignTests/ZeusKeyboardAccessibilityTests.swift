#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import ZeusDesign

@MainActor private final class KeyboardAuditPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private func keyboardAX(_ root: NSObject) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ root: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(root)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = root.responds(to: selector) ? root.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
        return [root] + (children + ((root as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}

@Suite(.serialized) @MainActor struct ZeusKeyboardAccessibilityTests {
    private func tabFrames(_ panel: NSPanel) -> [CGRect] {
        var visited: Set<ObjectIdentifier> = [], frames: [CGRect] = []
        for _ in 0..<30 {
            panel.selectNextKeyView(nil)
            guard let view = panel.firstResponder as? NSView, visited.insert(ObjectIdentifier(view)).inserted else { break }
            frames.append(view.frame)
        }
        return frames
    }
    @Test func stripSkipHasPlainLabelShortcutHintAndOneTabStopPerControl() async throws {
        let host = NSHostingView(rootView: ZeusStatusStrip(.waiting(questions: 1), onJump: {}, onSkip: {})
            .frame(width: 520).environment(\.accessibilityEnabled, true))
        let panel = KeyboardAuditPanel(contentRect: CGRect(x: -20000, y: -20000, width: 520, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host; panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let skip = try #require(keyboardAX(host).first { (($0 as AnyObject).accessibilityLabel?() ?? nil) == "Skip" })
        #expect((skip as AnyObject).accessibilityHelp?() == "Command-Shift-J")
        let frames = tabFrames(panel)
        #expect(frames.count == 2, "Each of the two strip links must take one Tab, without duplicate focus wrappers")
    }

    @Test func choiceAndCheckboxHaveSingleFocusStopsAndExposeTheirValues() async throws {
        _ = NSApplication.shared
        let state = KeyboardAuditState()
        let host = NSHostingView(rootView: KeyboardAuditControls(state: state).padding(8).frame(width: 420)
            .environment(\.accessibilityEnabled, true))
        let panel = KeyboardAuditPanel(contentRect: CGRect(x: -20000, y: -20000, width: 420, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host; panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(tabFrames(panel).count == 3, "Two enabled choices and one checkbox; the disabled choice must not take focus")
        let checkbox = try #require(keyboardAX(host).first { ($0 as AnyObject).accessibilityRole?() == .checkBox })
        #expect((checkbox as AnyObject).accessibilityLabel?() == "Let my assistant control Zeus")
        #expect((checkbox as AnyObject).accessibilityPerformPress?() == true)
        #expect(state.checked)
        let codex = try #require(keyboardAX(host).first { (($0 as AnyObject).accessibilityLabel?() ?? nil) == "Codex. Installed" })
        #expect((codex as AnyObject).accessibilityPerformPress?() == true)
        #expect(state.selected == "codex")
    }

    @Test func stripIconsHaveOneStopEachAndDisabledClearDropsOutOfTheLoop() async throws {
        _ = NSApplication.shared
        let buttons = ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: true, canClear: false)
        let host = NSHostingView(rootView: ZeusStatusStrip(.waiting(questions: 1, buttons: buttons), onJump: {}, onSkip: {})
            .frame(width: 700).environment(\.accessibilityEnabled, true))
        let panel = KeyboardAuditPanel(contentRect: CGRect(x: -20000, y: -20000, width: 700, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host; panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(tabFrames(panel).count == 5, "Two links and three enabled icons; disabled Clear remains discoverable but takes no Tab")
        for item in buttons {
            #expect(keyboardAX(host).contains { (($0 as AnyObject).accessibilityLabel?() ?? nil) == item.button.title })
        }
    }
}

@MainActor @Observable private final class KeyboardAuditState {
    var checked = false
    var selected: String? = "claude"
}
private struct KeyboardAuditControls: View {
    @Bindable var state: KeyboardAuditState
    var body: some View {
        VStack {
            ZeusChoiceList([ZeusChoice(id: "claude", title: "Claude Code", detail: "Installed"),
                ZeusChoice(id: "codex", title: "Codex", detail: "Installed"),
                ZeusChoice(id: "opencode", title: "OpenCode", isEnabled: false)], selection: $state.selected)
            Toggle("Let my assistant control Zeus", isOn: $state.checked).toggleStyle(ZeusCheckboxStyle())
        }
    }
}
#endif
