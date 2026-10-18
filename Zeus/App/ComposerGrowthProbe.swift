#if DEBUG
import AppKit
import Foundation
import SwiftUI
import ZeusDesign
import ZeusProtocol

/// Opt-in standalone native-input verification. Refuses ordinary launches and sends only to preview.
/// Input is dispatched directly to this app's passive panel; no global events or capture are used.
@MainActor enum ComposerGrowthProbe {
    private static var defaultsDomain: String?
    static var requested: Bool { isRequested(ProcessInfo.processInfo.environment) }
    static func isRequested(_ environment: [String: String]) -> Bool { environment["ZEUS_COMPOSER_GROWTH_PROBE"] != nil }
    static func cleanup() {
        if let defaultsDomain { UserDefaults(suiteName: defaultsDomain)?.removePersistentDomain(forName: defaultsDomain) }
        defaultsDomain = nil
    }

    static func validatedHome(_ environment: [String: String]) throws -> URL {
        guard environment["ZEUS_COMPOSER_GROWTH_PROBE"] == "1", let home = environment["HOME"],
              environment["CFFIXED_USER_HOME"] == home,
              ManagedProbeIsolation.canonical(home) == home,
              URL(fileURLWithPath: home).deletingLastPathComponent().path == "/private/tmp",
              URL(fileURLWithPath: home).lastPathComponent.hasPrefix("zcomposer_"),
              environment["TMUX_TMPDIR"] == home + "/tmux" else { throw Failure("Invalid disposable composer environment") }
        _ = try ManagedProbeIsolation.home(environment)
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    /// A fresh domain and explicit file URLs avoid cfprefsd and Foundation home fallbacks.
    static func makeShell() -> ShellController {
        let name = "test.zeus.composer." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { preconditionFailure("Couldn't create isolated probe defaults") }
        defaultsDomain = name
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: NoCredentials())
        settings.managedSession = AppSettings.newManagedSession(enabled: false)
        settings.hasShownWelcome = true
        let home = (try? validatedHome(ProcessInfo.processInfo.environment))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(name)
        return ShellController(defaults: defaults, cards: CardStore(fileURL: home.appendingPathComponent("cards.json")), settings: settings)
    }

    private struct NoCredentials: OpenCodePasswordStoring {
        func read() throws -> String? { nil }
        func save(_ password: String?) throws { throw Failure("Composer probes cannot save credentials") }
    }

    static func start(shell: ShellController) {
        let env = ProcessInfo.processInfo.environment
        guard let root = try? validatedHome(env), shell.settings.managedSession?.enabled == false else {
            NSApplication.shared.terminate(nil); return
        }
        let home = root.path
        shell.messaging.previewEnabled = true
        shell.messaging.previewOutcome = .delivered
        shell.settings.typewriterEnabled = false
        shell.preparePassivePerformancePanel()
        for index in 0..<30 {
            let card = Card(kind: .message, body: "Composer fixture history \(index)", status: .dismissed)
            shell.cards.add(card); shell.cards.markSeen(id: card.id); shell.cards.markRevealed(id: card.id)
        }
        shell.showTalkPanel()
        Task { @MainActor in
            var records: [[String: Any]] = []
            do {
                let host = try findHost()
                let window = try require(host.window)
                try await settle(host)
                let editor = try findEditor(host)
                guard window.makeFirstResponder(editor), !window.isKeyWindow else { throw Failure("Probe must stay passive") }
                @MainActor func record(_ label: String) throws {
                    let current = try findEditor(host), clip = try require(current.superview)
                    let rect = clip.convert(clip.bounds, to: host)
                    let caret = clip.convert(window.convertFromScreen(current.firstRect(forCharacterRange: current.selectedRange(), actualRange: nil)), from: nil)
                    let caretVisible = clip.bounds.insetBy(dx: -2, dy: -2).contains(caret)
                    let fieldVisible = host.bounds.insetBy(dx: -2, dy: -2).contains(rect)
                    guard caretVisible, fieldVisible else { throw Failure("\(label): clipped field or caret") }
                    records.append(["case": label, "fieldHeight": clip.bounds.height, "scrollOffset": clip.bounds.minY,
                        "threadHeight": shell.cardPanelState.viewportForDiagnostics.height, "windowHeight": host.bounds.height,
                        "caretVisible": caretVisible, "fieldVisible": fieldVisible, "draft": shell.conversation.draft])
                }
                @MainActor func type(_ text: String) {
                    for character in text { editor.insertText(String(character), replacementRange: editor.selectedRange()) }
                }
                @MainActor func keyReturn(shift: Bool) throws {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        let event = try require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [],
                            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        window.sendEvent(event)
                    }
                }
                type("Line 1"); try await settle(host); try record("1-line")
                for line in 2...8 {
                    try keyReturn(shift: true); await Task.yield(); type("Line \(line)")
                    try await settle(host); try record("\(line)-line-shift-return")
                    guard shell.conversation.draft.split(separator: "\n", omittingEmptySubsequences: false).count == line else {
                        throw Failure("Shift-Return did not insert a newline")
                    }
                }
                editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                type(String(repeating: "A long wrapped line with readable words. ", count: 20))
                try await settle(host); try record("long-wrapped")
                try keyReturn(shift: false); try await settle(host); try record("after-send")
                guard shell.conversation.draft.isEmpty, shell.messaging.previewMessages.count == 1 else { throw Failure("Return must send and clear once") }
                let heights = records.compactMap { $0["fieldHeight"] as? CGFloat }
                let lineHeight = heights[1] - heights[0]
                guard lineHeight > 0,
                      (1..<6).allSatisfy({ abs(heights[$0] - heights[$0 - 1] - lineHeight) < 1 }),
                      (6...8).allSatisfy({ abs(heights[$0] - heights[5]) < 1 }),
                      abs(heights[9] - heights[0]) < 1 else { throw Failure("Field must grow line by line, cap at six, and shrink after send") }
                try write(["passed": true, "records": records], home: home)
            } catch {
                try? write(["passed": false, "error": String(describing: error), "records": records], home: home)
            }
            NSApplication.shared.terminate(nil)
        }
    }
    private struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
    private static func require<T>(_ value: T?) throws -> T { guard let value else { throw Failure("Missing native view or event") }; return value }
    private static func findHost() throws -> NSHostingView<ConversationView> {
        try require(NSApplication.shared.windows.compactMap { $0.contentView as? NSHostingView<ConversationView> }.first)
    }
    private static func findEditor(_ view: NSView) throws -> NSTextView {
        func find(_ view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView, editor.isEditable { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        return try require(find(view))
    }
    private static func settle(_ host: NSView) async throws {
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private static func write(_ object: [String: Any], home: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: home).appendingPathComponent("composer-result.json"), options: .atomic)
    }
}
#endif
