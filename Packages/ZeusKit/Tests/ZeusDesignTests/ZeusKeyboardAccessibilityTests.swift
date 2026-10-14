#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import ZeusDesign

@MainActor private final class KeyboardAuditPanel: NSPanel {
    var allowsKeys = false
    override var canBecomeKey: Bool { allowsKeys }
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_A12_LIVE_KEYS"] == "1", "Requires an unlocked Mac; private offscreen window only."))
    func nativeChoiceAndCheckboxUseSpaceAndLeaveReturnToTheWindow() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let state = KeyboardAuditState()
        let host = NSHostingView(rootView: KeyboardAuditControls(state: state).padding(8).frame(width: 420)
            .environment(\.accessibilityEnabled, true))
        let panel = KeyboardAuditPanel(contentRect: CGRect(x: -20000, y: -20000, width: 420, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.allowsKeys = true; panel.isReleasedWhenClosed = false; panel.contentView = host
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        app.activate(); panel.makeKeyAndOrderFront(nil)
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        try #require(panel.isKeyWindow && app.isActive)
        func focus(_ label: String) async throws {
            let node = try #require(keyboardAX(host).first { ($0 as AnyObject).accessibilityLabel?() == label })
            let target = try #require((node as AnyObject).accessibilityFrame?())
            for _ in 0..<12 {
                if let view = panel.firstResponder as? NSView {
                    let rect = panel.convertToScreen(view.convert(view.bounds, to: nil))
                    if target.contains(CGPoint(x: rect.midX, y: rect.midY)) { return }
                }
                panel.selectNextKeyView(nil); try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Tab didn't reach \(label)"); throw CocoaError(.coderValueNotFound)
        }
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            app.sendEvent(event)
        }
        try await focus("Codex. Installed")
        try key("\r", code: 36)
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.selected == "claude")
        try key(" ", code: 49, modifiers: .option)
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.selected == "claude")
        try key(" ", code: 49)
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.selected == "codex")
        try await focus("Let my assistant control Zeus")
        try key("\r", code: 36)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.checked)
        try key(" ", code: 49)
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.checked)
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
