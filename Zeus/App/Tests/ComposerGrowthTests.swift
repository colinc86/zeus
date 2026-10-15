import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class GrowthPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private final class GrowthMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}

@Suite(.serialized) @MainActor struct ComposerGrowthTests {
    @Test(arguments: [ZeusFontChoice.system, .pixel])
    func fieldGrowsToItsLineCapAndReturnsToOneLineAfterSend(font: ZeusFontChoice) async throws {
        #expect(ZeusFonts.registerBundled())
        let suite = "zeus-composer-growth-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.fontChoice = font; settings.typewriterEnabled = false
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging = GrowthMessaging()
        for index in 0..<30 { cards.add(Card(kind: .message, body: "History \(index)")) }
        let model = ConversationModel(cards: cards, messaging: messaging), panel = ConversationPanelState(), activity = SurfaceActivity()
        panel.screenHeight = 600
        let window = GrowthPanel(contentRect: CGRect(x: -10000, y: -10000, width: 380, height: 250),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        defer { panel.isVisible = false; window.orderOut(nil); window.contentView = nil; window.close() }
        let host = TestHostingView(rootView: ConversationView(settings: settings, store: cards, model: model, messaging: messaging,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity, openSettings: {}, copySetup: {},
            resize: { height in window.setContentSize(CGSize(width: 380, height: height)) }))
        window.contentView = host; host.layoutSubtreeIfNeeded()
        panel.isVisible = true; model.openPanel(viewportManaged: true)
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        window.orderFront(nil); panel.focusRequest += 1
        func settle() async throws {
            for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        try await settle()
        func editors(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(editors)
        }
        let editor = try #require(editors(host).first)
        #expect(window.makeFirstResponder(editor) && !window.isKeyWindow)
        func replace(_ text: String) async throws -> CGFloat {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            try await settle()
            #expect(model.draft == text)
            let field = try #require(editor.superview)
            let rect = field.convert(field.bounds, to: host)
            #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(rect))
            let caretOnScreen = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let caret = field.convert(window.convertFromScreen(caretOnScreen), from: nil)
            #expect(field.bounds.insetBy(dx: -2, dy: -2).contains(caret))
            if text.split(separator: "\n", omittingEmptySubsequences: false).count == 3 {
                let firstLine = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
                #expect(field.bounds.insetBy(dx: -2, dy: -2).contains(field.convert(window.convertFromScreen(firstLine), from: nil)))
            }
            print("COMPOSER \(font) lines=\(text.split(separator: "\n", omittingEmptySubsequences: false).count) height=\(field.bounds.height) thread=\(panel.viewportForDiagnostics.height) window=\(host.bounds.height)")
            return field.bounds.height
        }
        let one = try await replace("One line")
        let threadBefore = panel.viewportForDiagnostics.height
        let three = try await replace("First line\nSecond line\nThird line")
        #expect(three > one * 2)
        let six = try await replace((1...ZeusTheme.Conversation.composerLines.upperBound).map { "Line \($0)" }.joined(separator: "\n"))
        let five = try await replace((1...5).map { "Line \($0)" }.joined(separator: "\n"))
        let lineHeight = six - five
        #expect(abs((three - one) - 2 * lineHeight) < 2)
        let eight = try await replace((1...8).map { "Line \($0)" }.joined(separator: "\n"))
        #expect(six > three && abs(eight - six) < 2)
        #expect(panel.viewportForDiagnostics.height < threadBefore - (six - one) + 3)
        #expect(host.bounds.height <= panel.screenHeight * ZeusTheme.Conversation.maxHeightFraction + 1)
        let field = try #require(editor.superview)
        #expect(field.bounds.minY > 0)
        let wrapped = try await replace(String(repeating: "A long wrapped line with readable words. ", count: 20))
        #expect(abs(wrapped - six) < 2)
        await ConversationView.sendFromComposer(model); try await settle()
        #expect(model.draft.isEmpty && abs(field.bounds.height - one) < 2)
    }
}
