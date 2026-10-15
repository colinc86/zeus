import AppKit
import Foundation
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private struct StripPasswords: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@MainActor private final class StripTransport: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}
@MainActor private final class StripNativeFixture {
    let suite = "zeus-tb1-native-\(UUID())"
    let root: URL, defaults: UserDefaults, settings: AppSettings, cards: CardStore, model: ConversationModel
    let transport = StripTransport(), panel = ConversationPanelState(), activity = SurfaceActivity()
    let window: StripPanel
    var host: TestHostingView?
    init() throws {
        _ = ZeusFonts.registerBundled()
        defaults = try #require(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: StripPasswords())
        settings.fontChoice = .system; settings.typewriterEnabled = false
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        model = ConversationModel(cards: cards, messaging: transport)
        window = StripPanel(contentRect: CGRect(x: -10000, y: -10000, width: 420, height: 600), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        panel.width = 420; panel.screenHeight = 900
    }
    func mount(avatar: Bool = false) {
        let status = AvatarStatusModel(cards: cards)
        if avatar, let target = StatusStripState.avatarTarget(cards: .init(values: cards.cards, seen: cards.seenIDs), status: status.presentation) {
            panel.scrollTargetCardID = target.cardID; panel.focusScrollTarget = true
        }
        let view = ConversationView(settings: settings, store: cards, model: model, messaging: transport, status: status,
            panel: panel, activity: activity, openSettings: {}, copySetup: {}, resize: { [weak window] height in window?.setContentSize(CGSize(width: 420, height: height)) })
        let host = TestHostingView(rootView: AnyView(view.environment(\.accessibilityEnabled, true).transaction { $0.disablesAnimations = true }))
        self.host = host; window.contentView = host; host.layoutSubtreeIfNeeded()
        panel.isVisible = true; model.openPanel(viewportManaged: true)
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        window.orderFront(nil); panel.focusRequest += 1
    }
    func wait(_ label: String = "layout", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            host?.layoutSubtreeIfNeeded(); host?.displayIfNeeded()
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "TB1Native", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(label): viewport \(panel.viewportForDiagnostics), focus \(String(describing: panel.focusedControlForDiagnostics)), reply \(model.replyTarget?.id ?? "nil"), target \(panel.scrollTargetCardID ?? "nil")"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func key(_ character: String, modifiers: NSEvent.ModifierFlags) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: 38))
        return window.performKeyEquivalent(with: event)
    }
    func render(_ name: String) throws {
        guard ProcessInfo.processInfo.environment["ZEUS_TB1_RENDER"] == "1", let host else { return }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
        var worktree = URL(fileURLWithPath: #filePath); for _ in 0..<4 { worktree.deleteLastPathComponent() }
        let output = worktree.appendingPathComponent("TestFixtures/live/tb1"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
    func cleanup() {
        panel.isVisible = false; window.orderOut(nil); window.contentView = nil; window.close()
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) @MainActor struct StatusStripNativeTests {
    @Test func commandJLoadsAnOlderQuestionFocusesItsOptionAndCyclesThenShiftJSkipsOldest() async throws {
        let f = try StripNativeFixture(); defer { f.cleanup() }
        let origin = Date(timeIntervalSince1970: 1)
        let a = Card(id: "old", kind: .question, title: "Older question", body: "Pick one", options: [.init(id: "same", label: "First choice")], createdAt: origin)
        let b = Card(id: "next", kind: .question, title: "Next question", body: "Tell me", input: InputSpec(), createdAt: origin.addingTimeInterval(1))
        f.cards.add(a); f.cards.add(b)
        for index in 0..<310 { f.cards.add(Card(kind: .message, body: "Read history \(index)", createdAt: origin.addingTimeInterval(Double(index+2)))) }
        f.cards.markAllSeen(); f.model.beginPlainMessage(); f.mount()
        try await f.wait("viewport") { f.panel.viewportForDiagnostics.height > 0 }
        #expect(try f.key("j", modifiers: .command))
        try await f.wait("oldest option") { f.panel.focusedControlForDiagnostics == .init(entryID: "card:old", controlID: "option:same") }
        #expect(f.model.replyTarget?.id == a.id && !f.panel.atBottom)
        #expect(try f.key("j", modifiers: .command))
        try await f.wait("next reply") { f.panel.focusedControlForDiagnostics == .init(entryID: "card:next", controlID: "reply") }
        #expect(f.model.replyTarget?.id == b.id)
        #expect(try f.key("J", modifiers: [.command,.shift]))
        try await f.wait("Skip response") { f.cards.card(id: a.id)?.response?.skipped == true }
        #expect(f.cards.card(id: b.id)?.status == .open && f.cards.card(id: a.id)?.response?.text == nil)
    }
    @Test func avatarOpeningUsesTheQuestionTargetAndSkipKeepsOnlyTheAgentBubble() async throws {
        let f = try StripNativeFixture(); defer { f.cleanup() }
        f.settings.fontChoice = .pixel
        let q = Card(id: "avatar-question", kind: .question, title: "Avatar question", body: "Choose", options: [.init(id: "one", label: "One")])
        f.cards.add(q); f.cards.markSeen(id: q.id); f.model.beginPlainMessage(); f.mount(avatar: true)
        try await f.wait("avatar option") { f.panel.focusedControlForDiagnostics == .init(entryID: "card:avatar-question", controlID: "option:one") }
        #expect(f.model.replyTarget?.id == q.id && f.panel.scrollTargetCardID == q.id)
        for _ in 0..<8 { f.host?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        try f.render("waiting")
        #expect(try f.key("J", modifiers: [.command,.shift]))
        try await f.wait("Skip response") { f.cards.card(id: q.id)?.response?.skipped == true }
        #expect(f.model.thread.count == 1)
        // Let the native host lay out the response before capturing the local view bitmap.
        for _ in 0..<8 { f.host?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        // Thread static Text is absent from this offscreen accessibility tree; inspect
        // the optional native bitmap for the caption, rather than inventing an AX node.
        try f.render("skipped")
    }
}

@MainActor struct ConversationStripKeyTests {
    @Test func exactModifiersAndDisabledSkipNeverFallThroughToJump() throws {
        let view = ConversationStripKeys.KeyView()
        var jumps = 0, skips = 0
        view.jump = { jumps += 1 }; view.skip = { skips += 1 }
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 38))
            return view.performKeyEquivalent(with: event)
        }
        #expect(try key("j", .command) && jumps == 1 && skips == 0)
        #expect(try key("J", [.command, .shift]) && jumps == 1 && skips == 1)
        #expect(try key("j", [.command, .option]) == false)
        #expect(try key("j", [.command, .control]) == false)
        #expect(try key("j", []) == false)
        view.skip = nil
        #expect(try key("J", [.command, .shift]) == false)
        #expect(jumps == 1 && skips == 1)
    }
}

@MainActor private final class StripTerminalOpener: ManagedTerminalOpening {
    var files: [URL] = []
    func open(commandFile: URL) async throws { files.append(commandFile) }
}
@MainActor struct ConversationTerminalTests {
    @Test func terminalTargetsStayScopedAndTheOpenerReceivesAPrivateQuotedCommand() async throws {
        let session = ConnectedSession(id: UUID(), sessionKey: "codex:/fixture#1.1", agent: .codex, cwd: "/fixture", clientName: nil,
            supportsChannel: false, tmuxPane: "%7", connectedAt: Date(), tmuxSocketPath: "/tmp/my socket")
        #expect(ConversationTerminalTarget.make(session: nil, configuredPane: nil, configuredSocket: nil) == nil)
        #expect(ConversationTerminalTarget.make(session: session, configuredPane: "%2", configuredSocket: "/tmp/another") == nil)
        #expect(ConversationTerminalTarget.make(session: session, configuredPane: "-L", configuredSocket: "/tmp/my socket") == nil)
        let target = try #require(ConversationTerminalTarget.make(session: session, configuredPane: nil, configuredSocket: nil))
        #expect(target.pane == "%7")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-tb1-terminal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = StripTerminalOpener(), helper = ConversationTerminal(directory: root, opener: opener)
        try await helper.open(target, executable: URL(fileURLWithPath: "/fixture/O'Brien/tmux"))
        let file = try #require(opener.files.first)
        #expect(file.deletingLastPathComponent().path == root.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "#!/bin/sh\nexec " + target.command(executable: URL(fileURLWithPath: "/fixture/O'Brien/tmux")) + "\n")
        #expect(target.command(executable: URL(fileURLWithPath: "/fixture/O'Brien/tmux")).contains("O'\\''Brien"))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o700)
    }
}
