#if LM2B_PROBE_HOST
import AppKit
import ApplicationServices
import Carbon
import Foundation
import ZeusProtocol

@MainActor private final class ProbeKey: JournalKeyProviding { func key() throws -> Data { Data(repeating: 86, count: 32) } }
@main private struct LM2BNativeHost {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let root = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                guard root.path.contains("/zlm2b_"), CommandLine.arguments.count == 2,
                      root == URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath() else { throw CocoaError(.fileReadNoPermission) }
                let permission = CGPreflightScreenCaptureAccess()
                var result: [String: JSONValue] = ["private_home": true, "screen_recording_granted": .bool(permission),
                    "accessibility_granted": .bool(AXIsProcessTrusted()), "safari_automation_status": .number(Double(automationStatus("com.apple.Safari")))]
                guard permission else {
                    result["status"] = "blocked"; result["reason"] = "Screen Recording is not granted to the isolated native host. No permission was requested and no window was read."
                    try output(result); app.terminate(nil); return
                }
                // Only this process's synthetic window is ever passed to the production capture source.
                let window = NSWindow(contentRect: .init(x: 200, y: 200, width: 720, height: 420),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.title = "LM2-B synthetic editor"
                let text = NSTextView(frame: .init(x: 0, y: 0, width: 720, height: 420))
                text.string = "Synthetic owned window\nReview safe fixture.swift\nContact sample@example.invalid\nlet example = 1\n"
                text.font = .monospacedSystemFont(ofSize: 18, weight: .regular); window.contentView = text
                window.makeKeyAndOrderFront(nil); app.activate()
                defer { window.close() }
                for _ in 0..<30 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                      window.windowNumber > 0 else { throw CocoaError(.fileReadNoPermission) }
                let context = ScreenContext(bundleID: Bundle.main.bundleIdentifier ?? "local.zeus.lm2b", appName: "Synthetic Editor", windowTitle: "LM2-B synthetic editor",
                    windowID: UInt32(window.windowNumber), processID: ProcessInfo.processInfo.processIdentifier)
                let journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: ProbeKey())
                let observer = ScreenObserver(journal: journal, redactor: LocalRedactor(useOnDeviceModel: false),
                    policy: { ScreenPolicy(enabled: true, consented: true) }, context: { context })
                observer.start(); defer { observer.stop() }
                let capture = await observer.captureOnDemand()
                let records = try journal.items(matching: .init())
                result["captured_own_window"] = .bool(capture?.identity.processID == ProcessInfo.processInfo.processIdentifier)
                result["frame_kept"] = .bool(capture?.frame != nil)
                result["description_kept"] = .bool(records.contains { $0.kind == .description })
                result["covered_areas"] = .number(Double(capture?.frame?.value.boxes.count ?? 0))
                result["pause"] = .string(observer.pause?.rawValue ?? "none")
                result["status"] = capture?.frame != nil ? "owned-window-passed" : "blocked"
                result["real_terminal_safari"] = "Not attempted: private HOME alone does not isolate native browser or Terminal restoration/settings. Safari additionally needs positive private-window classification."
                try output(result)
            } catch { try? output(["status": "blocked", "reason": "The isolated native capture did not complete. No other window was captured."]) }
            app.terminate(nil)
        }
        app.run()
    }
    @MainActor private static func output(_ result: [String: JSONValue]) throws { print(String(decoding: try ZeusJSON.encoder().encode(result), as: UTF8.self)); fflush(stdout) }
    @MainActor private static func automationStatus(_ bundle: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    }
}
#endif
