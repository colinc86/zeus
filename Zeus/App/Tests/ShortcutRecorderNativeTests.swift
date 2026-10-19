import AppKit
import Carbon
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private struct ShortcutNoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@MainActor private final class ShortcutNativeRegistration: ShortcutRegistering {
    var error: String?
    var refuse = false
    func suspend() {}
    func resume(_ shortcut: TalkHotKey) { error = refuse && shortcut.keyCode == UInt32(kVK_F5) ? "That shortcut is taken by another app." : nil }
}
@MainActor private final class ShortcutNativePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ rect: NSRect, to screen: NSScreen?) -> NSRect { rect }
}
@MainActor @Suite(.serialized) struct ShortcutRecorderNativeTests {
    @Test func nativeFieldStartsWithSpaceCapturesLocallyAndExposesItsValue() async throws {
        try await exercise(evidence: false)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_KR1_RENDER"] == "1" || ProcessInfo.processInfo.environment["KR1_RENDER"] == "1"))
    func renderRecorderStates() async throws { try await exercise(evidence: true) }

    private func exercise(evidence: Bool) async throws {
        _ = NSApplication.shared
        let suite = TestDefaults.suite("zeus-kr1-native"), defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: ShortcutNoCredentials())
        let registration = ShortcutNativeRegistration(), hotKey = GlobalHotKey()
        let recorder = ShortcutRecorderModel(registration: registration, current: { settings.talkHotKey }, save: { settings.talkHotKey = $0 })
        let window = ShortcutNativePanel(contentRect: CGRect(x: -10000, y: -10000, width: 490, height: 150),
                                        styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { recorder.cancel(); window.orderOut(nil); window.contentView = nil; window.close(); hotKey.stop() }
        let panel = AnyView(ZeusShortcutRecorder(settings: settings, hotKey: hotKey, recorder: recorder).padding(24)
            .environment(\.accessibilityEnabled, true))
        let host = TestHostingView(rootView: panel)
        window.contentView = host; window.orderFront(nil)
        func settle() async throws { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) } }
        func fields(_ view: NSView) -> [NSControl] {
            (view as? NSControl).map { $0.accessibilityLabel() == "Talk to Zeus shortcut" ? [$0] : [] } ?? view.subviews.flatMap(fields)
        }
        func render(_ name: String) throws {
            guard evidence else { return }
            var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
            let out = repo.appendingPathComponent("build/kr1-render")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for scale in [1,2] {
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale,
                    pixelsHigh: Int(host.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = host.bounds.size
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + "-\(scale)x.png"))
            }
        }
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: UInt16(code)))
        }
        for scheme in evidence ? [ColorScheme.light,.dark] : [.light] {
            let palette = ZeusPalette.for(scheme)
            host.setRootView(AnyView(panel.background(palette.panel).environment(\.colorScheme, scheme)))
            settings.talkHotKey = TalkHotKey(); try await settle()
            let field = try #require(fields(host).first)
            #expect(field.isAccessibilityElement() && field.accessibilityValue() as? String == "⌥⌘Z")
            let prefix = scheme == .light ? "light" : "dark"
            try render(prefix + "-idle")
            #expect(window.makeFirstResponder(field)); try await settle(); try render(prefix + "-focused")
            field.keyDown(with: try key(kVK_Space)); try await settle()
            #expect(recorder.isRecording && field.accessibilityValue() as? String == "Recording")
            try render(prefix + "-recording-a")
            if evidence { try await Task.sleep(for: .milliseconds(1000)); try render(prefix + "-recording-b") }
            // NSApplication's real local-event monitor, scoped to this offscreen fixture window.
            NSApp.sendEvent(try key(kVK_Space, [.control,.option])); try await settle()
            #expect(!recorder.isRecording && settings.talkHotKey.displayName == "⌃⌥Space")
            registration.refuse = true; recorder.start(); recorder.handle(try key(kVK_F5)); try await settle()
            #expect(recorder.error == "That shortcut is taken by another app.")
            try render(prefix + "-taken")
            recorder.clear(); try await settle(); try render(prefix + "-none")
            #expect(!settings.talkHotKey.enabled && field.accessibilityValue() as? String == "None" && !field.isEnabled)
            #expect(GeneralSettingsView.shortcutCaption(settings.talkHotKey).hasPrefix("The shortcut is off."))
            settings.talkHotKey = TalkHotKey(keyCode: UInt32(kVK_Space), command: false, option: true, control: true, enabled: false)
            try await settle(); try render(prefix + "-disabled")
            #expect(field.accessibilityValue() as? String == "⌃⌥Space" && !field.acceptsFirstResponder)
            recorder.cancel(); window.makeFirstResponder(nil)
        }
    }
}
