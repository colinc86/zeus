import AppKit
import Foundation
import SwiftUI
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class TalkFixturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private final class TalkFixtureTransport: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var messages: [String] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { messages.append(text); return .delivered }
}

/// Real editor + ConversationView, entirely offscreen and never key; no posted input or screen capture.
@Suite(.serialized) @MainActor struct TalkFocusNativeTests {
    @Test func nativeComposerAfterTalkProducesAMessageInsteadOfAHistoricalAnswer() async throws {
        let suite = "zeus-talk-native-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-talk-native-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.typewriterEnabled = false; settings.fontChoice = .system
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), transport = TalkFixtureTransport()
        let model = ConversationModel(cards: cards, messaging: transport), panel = ConversationPanelState(), activity = SurfaceActivity()
        let old = Card(kind: .question, title: "QA: free text", body: "Historical question", input: InputSpec(),
                       sessionKey: "claude:/Other#100.1", createdAt: Date().addingTimeInterval(-86400))
        cards.add(old); model.beginPlainMessage()
        let window = TalkFixturePanel(contentRect: CGRect(x: -10000, y: -10000, width: 380, height: 550),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        defer { panel.isVisible = false; window.orderOut(nil); window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ConversationView(settings: settings, store: cards, model: model, messaging: transport,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity, openSettings: {}, copySetup: {}, resize: { _ in }))
        window.contentView = host; host.layoutSubtreeIfNeeded()
        panel.isVisible = true; model.openPanel(viewportManaged: true)
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        window.orderFront(nil); panel.focusRequest += 1
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func editors(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(editors)
        }
        let fields = editors(host)
        #expect(fields.count == 1) // Historical questions don't add an automatically focused editor.
        let composer = try #require(fields.first)
        #expect(window.makeFirstResponder(composer) && !window.isKeyWindow)
        composer.insertText("A new managed message", replacementRange: NSRange(location: 0, length: 0))
        for _ in 0..<5 { await Task.yield() }
        #expect(model.draft == "A new managed message" && model.replyTarget == nil)
        await ConversationView.sendFromComposer(model)
        #expect(transport.messages == ["A new managed message"])
        #expect(cards.card(id: old.id)?.response == nil && cards.card(id: old.id)?.status == .open)
    }
}
