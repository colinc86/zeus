#if KR1_PROBE_HOST
import AppKit
import Carbon
import SwiftUI
import ZeusDesign
import ZeusProtocol

@MainActor private struct KR1Credentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@main private struct KR1RuntimeHost {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
                let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
                guard root.path.contains("/zkr1_"), URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == root else { throw CocoaError(.fileReadNoPermission) }
                guard let defaults = UserDefaults(suiteName: "zeus-kr1-live") else { throw CocoaError(.fileReadUnknown) }
                let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: KR1Credentials())
                settings.hasShownWelcome = true
                // Avoid competing with the human's running Zeus/default shortcut.
                settings.talkHotKey = TalkHotKey(keyCode: UInt32(kVK_F19), command: false, option: true, control: true, shift: true)
                let shell = ShellController(defaults: defaults, cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), settings: settings)
                shell.start()
                defer { shell.stop() }
                let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 620, height: 170), styleMask: [.titled,.closable], backing: .buffered, defer: false)
                window.title = "Zeus KR1 private fixture"; window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: ZeusShortcutRecorder(settings: settings, hotKey: shell.hotKey).padding(24)
                    .environment(\.zeusFontChoice, .system).environment(\.colorScheme, .light).background(ZeusPalette.light.panel))
                app.activate(); window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(300))
                try write(["ready": true, "private_home": true, "post_access": .bool(CGPreflightPostEventAccess()), "initial_error": shell.hotKey.error.map(JSONValue.string) ?? .null])
                while let data = await Task.detached(operation: { () -> Data? in
                    var line = Data()
                    while let b = try? FileHandle.standardInput.read(upToCount: 1), !b.isEmpty {
                        if b[0] == 10 { return line }; line.append(b[0])
                    }
                    return nil
                }).value {
                    do {
                        let value = try ZeusJSON.decoder().decode(JSONValue.self, from: data)
                        switch value["command"] {
                        case .string("record"):
                            @MainActor func find(_ view: NSView) -> NSControl? {
                                if let field = view as? NSControl, field.accessibilityLabel() == "Talk to Zeus shortcut" { return field }
                                for child in view.subviews { if let field = find(child) { return field } }; return nil
                            }
                            guard let rootView = window.contentView, let field = find(rootView) else { throw CocoaError(.coderValueNotFound) }
                            window.makeFirstResponder(nil); window.recalculateKeyViewLoop()
                            var foundByTab = false
                            for _ in 0..<12 {
                                window.selectNextKeyView(nil)
                                if window.firstResponder === field { foundByTab = true; break }
                            }
                            guard foundByTab else { throw CocoaError(.coderValueNotFound) }
                            guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: UInt16(kVK_Space)) else { throw CocoaError(.coderInvalidValue) }
                            field.keyDown(with: space)
                            guard let combo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control,.option], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: UInt16(kVK_Space)) else { throw CocoaError(.coderInvalidValue) }
                            app.sendEvent(combo)
                            try await Task.sleep(for: .milliseconds(300))
                            try write(["ok": true, "shortcut": .string(settings.talkHotKey.displayName), "error": shell.hotKey.error.map(JSONValue.string) ?? .null,
                                       "tab_reached_field": .bool(foundByTab), "saved": .bool(AppSettings(defaults: defaults, userDirectory: nil, passwordStore: KR1Credentials()).talkHotKey == settings.talkHotKey)])
                        case .string("fire"):
                            window.orderOut(nil)
                            guard CGPreflightPostEventAccess(), let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true),
                                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: false) else {
                                try write(["ok": true, "opened": false, "reason": "Native global event posting is unavailable; no permission requested."]); continue
                            }
                            down.flags = [.maskControl,.maskAlternate]; up.flags = [.maskControl,.maskAlternate]
                            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                            for _ in 0..<30 { if shell.cardPanelState.isVisible { break }; try await Task.sleep(for: .milliseconds(50)) }
                            try write(["ok": true, "opened": .bool(shell.cardPanelState.isVisible), "mounted": .bool(shell.isConversationMounted), "route": "real Carbon global hotkey"])
                        default: try write(["ok": false, "error": "Unknown KR1 command"])
                        }
                    } catch { try? write(["ok": false, "error": .string(error.localizedDescription)]) }
                }
                window.orderOut(nil); app.terminate(nil)
            } catch { try? write(["ready": false, "error": .string(error.localizedDescription)]); app.terminate(nil) }
        }
        app.run()
    }
    static func write(_ value: [String: JSONValue]) throws {
        var data = try ZeusJSON.encoder().encode(JSONValue.object(value)); data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
    }
}
#endif
