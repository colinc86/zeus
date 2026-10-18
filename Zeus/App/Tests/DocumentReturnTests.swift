import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class DV2Messaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}
@MainActor private final class DV2Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private struct DV2Passwords: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}

@MainActor private final class DV2Fixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "zeus-dv2-\(UUID())"
    let cards: CardStore
    let settings: AppSettings
    let messaging = DV2Messaging()
    let model: ConversationModel
    let panel = ConversationPanelState()
    let activity = SurfaceActivity()
    let window: NSPanel
    var host: TestHostingView?
    let attachment: ZeusProtocol.Attachment
    let second: ZeusProtocol.Attachment
    let sourceID: String
    init(index: Int, count: Int = 430) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: DV2Passwords())
        settings.typewriterEnabled = false; settings.fontChoice = .system
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        model = ConversationModel(cards: cards, messaging: messaging)
        attachment = .init(kind: .file, label: "Read.md", target: root.appendingPathComponent("Read.md").path)
        second = .init(kind: .file, label: "Next.md", target: root.appendingPathComponent("Next.md").path)
        try "# Read\n\nA synthetic document.".write(toFile: attachment.target, atomically: true, encoding: .utf8)
        try "# Next".write(toFile: second.target, atomically: true, encoding: .utf8)
        sourceID = "history-\(index)"
        let origin = Date().addingTimeInterval(-10000)
        for i in 0..<count {
            cards.add(Card(id: "history-\(i)", kind: .message,
                body: "History \(i). " + String(repeating: "A paragraph that wraps at the conversation width. ", count: i % 4 + 1),
                attachments: i == index ? [attachment, second] : [], createdAt: origin.addingTimeInterval(Double(i))))
        }
        model.draft = "Keep this draft"
        panel.screenHeight = 1000; panel.width = 380; panel.scrollTargetCardID = sourceID
        window = DV2Panel(contentRect: NSRect(x: -10000, y: -10000, width: 380, height: 600), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
    }
    func mount() {
        let view = ConversationView(settings: settings, store: cards, model: model, messaging: messaging,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity, openSettings: {}, copySetup: {},
            resize: { [weak self] height in
                guard let self else { return }
                let width: CGFloat = self.panel.document.isOpen && self.panel.document.expanded ? 760 : 380
                self.panel.width = width; self.window.setContentSize(NSSize(width: width, height: height))
            })
        let host = TestHostingView(rootView: view.environment(\.accessibilityEnabled, true))
        self.host = host; window.contentView = host; panel.isVisible = true
        model.openPanel(viewportManaged: true)
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        window.orderFront(nil)
    }
    func unmount() { panel.isVisible = false; model.closePanel(); window.contentView = nil; host = nil }
    func cleanup() {
        panel.document.close(); unmount(); window.close()
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
    }
    func settle() async throws {
        // Pump actual native layout until its frame and clip position stop changing.
        var last = CGRect.null; var stable = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && stable < 12 {
            host?.layoutSubtreeIfNeeded()
            let v = viewport
            let sample = CGRect(x: v.offset, y: v.contentHeight, width: panel.width, height: v.height)
            stable = sample == last && !panel.document.loading ? stable + 1 : 0; last = sample
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(stable >= 12)
    }
    var scroll: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let value = view as? NSScrollView { return value }
            return view.subviews.lazy.compactMap(find).first
        }
        return host.flatMap(find)
    }
    var viewport: ConversationViewport {
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        return driver.viewport ?? .init()
    }
    func chipFrame() throws -> CGRect {
        let node = try #require(host.flatMap { root in jumpAXNodes(root).first { ($0 as AnyObject).accessibilityRole?() == .button && ($0 as AnyObject).accessibilityLabel?() == AttachmentChip.accessibilityLabel(attachment) } })
        return (node as AnyObject).accessibilityFrame?() ?? .zero
    }
    func press(_ label: String) throws {
        let node = try #require(host.flatMap { root in jumpAXNodes(root).first { ($0 as AnyObject).accessibilityRole?() == .button && ($0 as AnyObject).accessibilityLabel?() == label } }, "Missing \(label)")
        #expect((node as AnyObject).accessibilityPerformPress?() == true)
    }
}

@MainActor @Suite(.serialized) struct DocumentReturnTests {
    enum ReturnPath: String, CaseIterable { case messages, escape, bracket, expanded, collapsed, reopened, stepped, linked, arrival }
    @Test(arguments: [100, 400, 428], ReturnPath.allCases)
    func returnsToSameVisibleContent(index: Int, path: ReturnPath) async throws {
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber ?? false
        NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { NSApp.perform(enhanced, with: previous, with: "AXEnhancedUserInterface") }
        let f = try DV2Fixture(index: index); defer { f.cleanup() }
        f.mount(); try await f.settle()
        if index == 100 { try f.press("Load Earlier Messages"); try await f.settle() }
        let driver = ConversationScrollDriver(); driver.scrollView = f.scroll
        driver.scroll(to: f.viewport.offset - 70); try await f.settle()
        let beforeWidth = f.scroll?.bounds.width
        let before = f.viewport.offset
        let beforeChip = try f.chipFrame()
        print("DV2 initial index=\(index) offset=\(before) chip=\(beforeChip) viewport=\(f.viewport)")
        try #require(before > 1000)
        try f.press(AttachmentChip.accessibilityLabel(f.attachment)); try await f.settle()
        #expect(f.panel.document.isOpen)
        print("DV2 bookmark \(String(describing: f.panel.document.threadBookmark))")
        #expect(abs((f.panel.document.threadOffset ?? -1) - before) < 3)
        if path == .arrival || path == .reopened {
            f.cards.add(Card(id: "arrival", kind: .message, body: "Arrived while reading"))
        }
        if [.expanded, .collapsed, .reopened].contains(path) {
            f.panel.document.expanded = true; try await f.settle()
            #expect(f.scroll?.bounds.width == beforeWidth)
        }
        if path == .collapsed { f.panel.document.expanded = false; try await f.settle() }
        if path == .reopened { f.unmount(); f.mount(); try await f.settle() }
        if path == .stepped { #expect(f.panel.document.step(1)); try await f.settle() }
        if path == .linked {
            #expect(f.panel.document.navigate(URL(fileURLWithPath: f.second.target))); try await f.settle()
            f.panel.document.backRequest += 1; try await f.settle()
            #expect(f.panel.document.isOpen)
        }
        if path == .escape || path == .bracket {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: path == .bracket ? .command : [], timestamp: 0,
                windowNumber: f.window.windowNumber, context: nil, characters: path == .bracket ? "[" : "\u{1b}",
                charactersIgnoringModifiers: path == .bracket ? "[" : "\u{1b}", isARepeat: false,
                keyCode: path == .bracket ? 33 : 53))
            let command = try #require(DocumentKeyboard.command(event))
            #expect(f.panel.document.handle(command, conversation: f.model))
        } else { try f.press("Back to Messages") }
        try await f.settle()
        print("DV2 \(path.rawValue) native return: before=\(before) after=\(f.viewport.offset) content=\(f.viewport.contentHeight)")
        print("DV2 chip before=\(beforeChip) after=\(try f.chipFrame())")
        #expect(abs(try f.chipFrame().minY - beforeChip.minY) < 3)
        #expect(!f.panel.document.isOpen)
        #expect(f.scroll?.bounds.width == beforeWidth)
        // A rebuilt LazyVStack estimates offscreen rows anew; content-relative position is authoritative.
        #expect(f.model.draft == "Keep this draft")
        // Offscreen fixtures do not take keyboard focus from the human. The existing
        // Q3 native return test checks actual chip focus in a key panel.
        if path != .reopened { #expect(abs(f.viewport.offset - before) < 3) }
    }
    @Test(arguments: [false, true])
    func emptyDraftCleanupRunsOnEveryCloseBoundary(explicit: Bool) async throws {
        let f = try DV2Fixture(index: 10, count: 30); defer { f.cleanup() }
        f.model.draft = ""; f.mount(); try await f.settle()
        for route in 0..<3 {
            #expect(f.panel.document.open(f.attachment))
            try await f.settle()
            f.panel.document.selectedText = "A quoted passage"
            f.panel.document.quote(in: f.model)
            if explicit { f.panel.document.ask(in: f.model) }
            // No intervening render: the text starts and finishes empty. The close
            // boundary must clean up even when SwiftUI coalesces the draft changes.
            f.model.draft = ""
            switch route {
            case 0: f.panel.document.backRequest += 1
            case 1: f.panel.document.close() // Pills and strip leave through close().
            default: _ = f.cards.clearConversation()
            }
            try await f.settle()
            #expect(!f.panel.document.isOpen)
            #expect(f.model.draftAttachments.isEmpty == !explicit, "close route \(route)")
            f.model.draftAttachments = []
        }
    }

}
