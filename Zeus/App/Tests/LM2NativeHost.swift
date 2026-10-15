#if LM2_PROBE_HOST
import AppKit
import ApplicationServices
import Foundation
import ZeusProtocol

@MainActor private final class LM2PrivateKey: JournalKeyProviding {
    func key() throws -> Data { Data(repeating: 71, count: 32) }
}
/// Captures only a PID launched by the private fixture. It refuses every other frontmost app before calling AX.
@main private struct LM2NativeHost {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--editor" {
            runEditor(root: CommandLine.arguments[2]); app.run(); return
        }
        Task { @MainActor in
            do {
                guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
                let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
                guard root.path.contains("/zlm2_"), URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == root,
                      let defaults = UserDefaults(suiteName: "zeus-lm2-private") else { throw CocoaError(.fileReadNoPermission) }
                let source = MacFocusCaptureSource(), settings = ObservationSettings(defaults: defaults)
                let store = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: LM2PrivateKey())
                let redactor = LocalRedactor()
                var owned: [NSRunningApplication] = []
                defer { for application in owned { application.terminate() } }
                try write(["ready": true, "ax_trusted": .bool(source.isTrusted), "private_home": true])
                while let line = await Task.detached(operation: { readLine() }).value {
                    let value = try ZeusJSON.decoder().decode(JSONValue.self, from: Data(line.utf8))
                    if value["command"] == .string("launchEditor") {
                        let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
                        configuration.environment = ["HOME": root.path, "CFFIXED_USER_HOME": root.path]
                        configuration.arguments = ["--editor", root.path]
                        let editor = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("LM2Editor.app")
                        let launched = try await NSWorkspace.shared.openApplication(at: editor, configuration: configuration)
                        owned.append(launched)
                        try write(["ok": true, "pid": .number(Double(launched.processIdentifier))]); continue
                    }
                    if value["command"] == .string("launchXcode") {
                        let document = root.appendingPathComponent("review-synthetic@example.invalid.swift")
                        try "// LM2 synthetic focus fixture\nlet example = 1\n".write(to: document, atomically: true, encoding: .utf8)
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.createsNewApplicationInstance = true
                        configuration.environment = ["HOME": root.path, "CFFIXED_USER_HOME": root.path]
                        let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").map(\.processIdentifier))
                        let launched = try await NSWorkspace.shared.open([document], withApplicationAt: URL(fileURLWithPath: "/Applications/Xcode.app"), configuration: configuration)
                        guard !existing.contains(launched.processIdentifier) else { try write(["ok": false, "reason": "New isolated Xcode instance unavailable"]); continue }
                        owned.append(launched)
                        try write(["ok": true, "pid": .number(Double(launched.processIdentifier))]); continue
                    }
                    guard case .number(let pidNumber) = value["pid"], case .string(let bundle) = value["bundle"],
                          ["com.apple.dt.Xcode", "com.apple.Safari", "com.example.LM2Editor"].contains(bundle), let target = NSRunningApplication(processIdentifier: pid_t(pidNumber)),
                          target.bundleIdentifier == bundle, owned.contains(where: { $0.processIdentifier == target.processIdentifier }) else { try write(["ok": false, "reason": "Not an owned fixture target"]); continue }
                    guard source.isTrusted else { try write(["ok": false, "skip": "Accessibility unavailable; no permission requested"]); continue }
                    NSApp.yieldActivation(to: target)
                    target.activate()
                    for _ in 0..<30 {
                        if source.application?.pid == target.processIdentifier { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard source.application?.pid == target.processIdentifier else { try write(["ok": false, "reason": "Owned fixture is not in front"]); continue }
                    settings.edit(2) { $0.enabled = true; $0.consented = true; $0.scope = .chosenApps; $0.apps = [.init(name: "Fixture", bundleIDs: [bundle])] }
                    var sawDocument = false, sawSyntheticEmail = false
                    let observer = FocusObserver(source: source, policies: settings, privateApps: { ExcludedApp.defaults }) { application, record in
                        guard application.pid == target.processIdentifier, application.bundleID == bundle else { throw CocoaError(.fileReadNoPermission) }
                        sawDocument = record.document?.contains("zlm2_") == true
                        sawSyntheticEmail = record.title.contains("synthetic@example.invalid")
                        let safe = await redactor.redact(JournalPayload(description: application.name, text: record.text))
                        return { try store.append(JournalItem(level: .focus, app: bundle, kind: .focus, payload: safe)) }
                    }
                    var attempts = 0
                    while attempts < 30 {
                        if !target.isActive && !target.isTerminated { NSApp.yieldActivation(to: target); target.activate() }
                        await observer.sample()
                        var check = JournalQuery(); check.apps = [bundle]
                        if try !store.items(matching: check).isEmpty { break }
                        attempts += 1; try await Task.sleep(for: .milliseconds(500))
                    }
                    var query = JournalQuery(); query.apps = [bundle]
                    let records = try store.items(matching: query)
                    let text = records.compactMap { $0.payload.value.text }.joined(separator: "\n")
                    try write(["ok": true, "captured": .bool(!records.isEmpty), "secure_input": .bool(source.isSecure), "locked": .bool(source.isLocked), "front_owned": .bool(source.application?.pid == target.processIdentifier), "owned_process_terminated": .bool(target.isTerminated), "stored_count": .number(Double(records.count)),
                        "document_read_from_ax": .bool(sawDocument), "synthetic_email_in_ax_title": .bool(sawSyntheticEmail),
                        "email_redacted": .bool(!text.contains("synthetic@example.invalid") && text.contains("‹email›")),
                        "safari_app_only": .bool(bundle == "com.apple.Safari" && text == "Window: Details not kept"),
                        "engine": .string(records.last?.payload.report.semanticEngine.rawValue ?? "none")])
                }
                app.terminate(nil)
            } catch { try? write(["ready": false, "error": "Private native probe failed"]); app.terminate(nil) }
        }
        app.run()
    }
    @MainActor private static var editorWindow: NSWindow?
    @MainActor private static func runEditor(root: String) {
        guard root.contains("/zlm2_"), URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: root).resolvingSymlinksInPath() else { return }
        NSApp.setActivationPolicy(.regular)
        let url = URL(fileURLWithPath: root).appendingPathComponent("review-synthetic@example.invalid.swift")
        try? "// LM2 synthetic native editor".write(to: url, atomically: true, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 480, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Review for synthetic@example.invalid"; window.representedURL = url
        window.contentView = NSTextField(labelWithString: "LM2 synthetic AX document fixture")
        window.isReleasedWhenClosed = false; editorWindow = window
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
    }
    private static func write(_ value: [String: JSONValue]) throws {
        var data = try ZeusJSON.encoder().encode(JSONValue.object(value)); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
#endif
