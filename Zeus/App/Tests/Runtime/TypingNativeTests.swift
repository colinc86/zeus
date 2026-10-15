import AppKit
import Carbon
import FoundationModels
import Testing
@testable import Zeus

/// Only this process's explicitly marked synthetic keys reach the probe. No global tap or user pasteboard is used.
@Suite(.serialized) @MainActor struct TypingNativeTests {
    private static let marker: Int64 = 0x5A4555534334
    @Test func syntheticOnDeviceRunAndTopic() async throws {
        guard ProcessInfo.processInfo.environment["ZEUS_TEST_LM2C_MODEL"] == "1" else { return }
        guard let home = ProcessInfo.processInfo.environment["ZEUS_LM2C_HOME"], NSHomeDirectory() == home else {
            Issue.record("LM2-C model gate blocked: disposable HOME was not inherited."); return
        }
        guard case .available = SystemLanguageModel.default.availability else {
            Issue.record("LM2-C model gate blocked: Apple Intelligence unavailable."); return
        }
        let inputs = ["please review this synthetic parser change with ‹pasted› later", "Please review a synthetic Swift change. All tests passed."]
        var checks: [[String: String]] = []
        for (index, input) in inputs.enumerated() {
            let safe = await RunRedactor(redactor: LocalRedactor()).redact(words: LocalRedactor.firstPass(input), app: "Editor")
            checks.append(["fixture": String(index), "result": safe == nil ? "mandatory semantic pass declined; run dropped" : "both redaction stages succeeded"])
            if let safe { #expect(safe.words.report.semanticEngine == .onDeviceModel) }
        }
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Preserve refused/fail-closed evidence even if the separate topic request cannot run.
        try encoder.encode(checks).write(to: Self.output.appendingPathComponent("synthetic-model-redaction.json"))
        // Independent schema proof on known synthetic text, not an observer bypass or a retained real typing run.
        let topic = try #require(await OnDeviceTypingTopic.shared.generate(app: "Editor", words: "Reviewing a synthetic Swift change"),
                                "Native topic generation unavailable/declined; no successful topic proof is claimed")
        let checked = TopicSummarizer.checked(topic, app: "Editor")
        try encoder.encode(checked).write(to: Self.output.appendingPathComponent("synthetic-on-device-topic.json"))
    }
    @Test func ownedEditorPasteAndSecureField() async throws {
        guard ProcessInfo.processInfo.environment["ZEUS_TEST_LM2C_NATIVE"] == "1" else { return }
        guard let home = ProcessInfo.processInfo.environment["ZEUS_LM2C_HOME"], NSHomeDirectory() == home else {
            Issue.record("LM2-C native gate blocked: disposable HOME was not inherited; no tap started."); return
        }
        guard CGPreflightListenEventAccess() else {
            try Self.evidence(["status": "blocked", "reason": "Input Monitoring preflight false; no tap, permission prompt or keys read"])
            Issue.record("LM2-C native gate blocked: Input Monitoring is not granted to this dev build."); return
        }
        guard case .available = SystemLanguageModel.default.availability else {
            try Self.evidence(["status": "blocked", "reason": "Apple Intelligence unavailable; no typing kept"])
            Issue.record("LM2-C native gate blocked: Apple Intelligence unavailable."); return
        }
        let root = URL(fileURLWithPath: home).appendingPathComponent("native-journal")
        let journal = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        let board = NSPasteboard(name: .init("zeus-lm2c-" + UUID().uuidString))
        board.clearContents(); board.setString("SYNTHETIC_PASTED_TOKEN_NEVER_CAPTURE", forType: .string)
        defer { board.releaseGlobally() }
        let oldPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(oldPolicy) }
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 600, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Zeus owned synthetic typing editor"; window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: .init(x: 0, y: 0, width: 600, height: 260))
        let editor = LM2CTypingEditor(frame: .init(x: 20, y: 100, width: 560, height: 140), pasteboard: board)
        let password = NSSecureTextField(frame: .init(x: 20, y: 30, width: 560, height: 30))
        content.addSubview(editor); content.addSubview(password); window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(); window.makeFirstResponder(editor)
        try await Task.sleep(for: .milliseconds(600))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), window.isKeyWindow else {
            Issue.record("LM2-C native gate blocked: owned editor did not become frontmost; no tap started."); return
        }
        let bundle = Bundle.main.bundleIdentifier ?? "com.colinc86.Zeus"
        let policy = TypingPolicy(enabled: true, consented: true, apps: [bundle])
        let context = TypingContext(bundleID: bundle, appName: "Synthetic Editor", windowID: UInt32(window.windowNumber), processID: getpid())
        let eventSource = MacTypingEventSource(ownedProcessFixtureMarker: Self.marker, pasteboardChangeCount: { board.changeCount })
        let observer = TypingObserver(journal: journal, redactor: LocalRedactor(), policy: { policy }, context: {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), window.isKeyWindow else { return nil }
            return context
        }, source: eventSource)
        observer.start(); defer { observer.stop() }
        try #require(observer.isRecording, "The owned process tap could not start")
        try await Self.type("review the synthetic change")
        try await Self.awaitRows(journal, count: 1)
        try await Self.type("review ")
        Self.post(code: 9, flags: .maskCommand)
        try await Self.type(" later please")
        try await Self.awaitRows(journal, count: 2)
        window.makeFirstResponder(password)
        try await Task.sleep(for: .milliseconds(200))
        let secure = IsSecureEventInputEnabled()
        #expect(secure, "The active NSSecureTextField must enable native secure input before the probe types")
        if secure { try await Self.type("synthetic password must not be kept") }
        try await Task.sleep(for: .seconds(3))
        let rows = try journal.items(matching: .init())
        #expect(rows.count == 2)
        #expect(rows.contains { $0.payload.value.text?.contains("‹pasted›") == true })
        #expect(!String(decoding: try journal.export(matching: .init()), as: UTF8.self).contains("SYNTHETIC_PASTED_TOKEN"))
        #expect(!rows.contains { $0.payload.value.text?.contains("password must") == true })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rows).write(to: Self.output.appendingPathComponent("owned-editor-journal.json"))
        try Self.evidence(["status": "passed", "scope": "per-process marked synthetic keys only; real LocalRedactor and on-device topics",
                           "runs": String(rows.count), "secureInput": String(secure), "paste": "private named pasteboard; contents never read by capture"])
    }
    private static var output: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestFixtures/live/lm2c")
    }
    private static func evidence(_ value: [String: String]) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: output.appendingPathComponent("native-gate.json"))
    }
    private static func post(code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags; event.setIntegerValueField(.eventSourceUserData, value: marker); event.postToPid(getpid())
        }
    }
    private static func type(_ text: String) async throws {
        let codes: [Character: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46," ":49]
        guard ["com.apple.keylayout.US", "com.apple.keylayout.ABC"].contains(TypingKeyTranslator.currentSourceID ?? "") else {
            throw LM2CNativeError.requiresUS // Never change the user's input-source preferences.
        }
        for char in text { if let code = codes[char] { post(code: code); try await Task.sleep(for: .milliseconds(30)) } }
    }
    private static func awaitRows(_ journal: EncryptedJournalStore, count: Int) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < until {
            if try journal.items(matching: .init()).count == count { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("LM2-C native run did not survive the required model pass within 30s")
    }
}
private enum LM2CNativeError: Error { case requiresUS }
@MainActor private final class LM2CTypingEditor: NSTextView {
    let board: NSPasteboard
    init(frame: NSRect, pasteboard: NSPasteboard) { board = pasteboard; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override func paste(_ sender: Any?) {
        // Only the owned test editor reads its own synthetic clipboard. Production capture reads changeCount only.
        insertText(board.string(forType: .string) ?? "", replacementRange: selectedRange())
    }
}
