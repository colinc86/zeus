import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor @Observable private final class Q3ScrollMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var assistantActivity: AssistantActivity?
    var outcome: MessageSendResult = .delivered
    func sendUserMessage(_ text: String) async -> MessageSendResult { outcome }
}

@MainActor private final class Q3OffscreenPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    /// Pins the backing scale, so layout doesn't depend on the test Mac's display (1x or Retina).
    var scale: CGFloat?
    override var backingScaleFactor: CGFloat { scale ?? super.backingScaleFactor }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Real ConversationView + native NSScrollView. Windows are entirely offscreen, never key,
/// never activated, and no keyboard/mouse input or screen capture is used.
@MainActor private final class Q3ScrollHarness {
    let root: URL
    let suite = TestDefaults.suite("zeus-q3-scroll")
    let defaults: UserDefaults
    let cards: CardStore
    let settings: AppSettings
    let messaging = Q3ScrollMessaging()
    let model: ConversationModel
    let panel = ConversationPanelState()
    let activity = SurfaceActivity()
    let window: NSPanel
    var host: TestHostingView?
    var newestID: String?

    init(longNewest: Bool, newestBody: String? = nil, scale: CGFloat? = nil) throws {
        var worktree = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { worktree.deleteLastPathComponent() }
        root = worktree.appendingPathComponent("build/q3-scroll/\(UUID())")
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.typewriterEnabled = false; settings.fontChoice = .system
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        model = ConversationModel(cards: cards, messaging: messaging)
        window = Q3OffscreenPanel(contentRect: CGRect(x: -10000, y: -10000, width: 380, height: 600),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        (window as? Q3OffscreenPanel)?.scale = scale
        panel.screenHeight = 1000
        let origin = Date(timeIntervalSince1970: 1_791_800_000)
        for index in 0..<30 {
            let card = Card(kind: .message, body: "History item \(index): read this earlier message.", createdAt: origin.addingTimeInterval(Double(index)))
            cards.add(card)
        }
        let newest = Card(kind: .message, body: newestBody ?? (longNewest ? String(repeating: "A long reply spans many visual lines. Read it from its top.\n", count: 70) : "The latest short reply."), createdAt: origin.addingTimeInterval(31))
        cards.add(newest); newestID = newest.id
    }

    func mount(target: String? = nil, duringOpening: (() -> Void)? = nil, accessibilityEnabled: Bool = false) {
        panel.isVisible = false; panel.scrollTargetCardID = target
        let view = ConversationView(settings: settings, store: cards, model: model, messaging: messaging,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity, openSettings: {}, copySetup: {},
            resize: { [weak window] height in
                guard let window else { return }
                window.setContentSize(CGSize(width: 380, height: height))
            })
        let root = AnyView(view.transaction { $0.disablesAnimations = true })
        let host = TestHostingView(rootView: accessibilityEnabled ? AnyView(root.environment(\.accessibilityEnabled, true)) : root)
        self.host = host; window.contentView = host
        // Establish the hidden host and its observation subscriptions before making it visible.
        // This mirrors ShellController.mountConversation -> position -> showInteractionPanel.
        host.layoutSubtreeIfNeeded()
        panel.isVisible = true
        model.openPanel(viewportManaged: true)
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        duringOpening?() // Deterministic arrival before the first visible layout, not a timing guess.
        window.orderFront(nil)
    }

    func unmount() {
        panel.isVisible = false; model.closePanel()
        window.contentView = nil; host = nil
    }

    func settle() async throws {
        for _ in 0..<30 { host?.layoutSubtreeIfNeeded(); host?.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    func append(_ text: String) {
        let card = Card(kind: .message, body: text, createdAt: Date())
        cards.add(card); newestID = card.id
        model.noteArrival(card, visible: panel.isVisible && panel.atBottom, animate: false)
    }
    func record(_ label: String) {
        let v = panel.viewportForDiagnostics
        print("Q3 scroll \(label): offset=\(v.offset) height=\(v.height) content=\(v.contentHeight) newestTop=\(String(describing: panel.newestMessageTopForDiagnostics)) pinned=\(panel.atBottom)")
        if let scroll = nativeScrollView(), let document = scroll.documentView {
            print("Q3 native \(label): documentHeight=\(document.bounds.height) clipHeight=\(scroll.contentView.bounds.height) clipY=\(scroll.contentView.bounds.minY) flipped=\(document.isFlipped)")
        }
    }
    func nativeScrollView() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.bounds.height > 150 { return scroll }
            for child in view.subviews { if let scroll = find(child) { return scroll } }
            return nil
        }
        return host.flatMap(find)
    }
    func cleanup() {
        window.orderOut(nil); window.contentView = nil; window.close()
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) @MainActor struct Q3NativeScrollAuditTests {
    @Test(arguments: [true, false]) func nativeComposerSendFollowsOnlyAcceptedMessagesFromHistory(accepted: Bool) async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        f.messaging.outcome = accepted ? .delivered : .failed(reason: "Private fixture unavailable")
        f.mount(accessibilityEnabled: true); try await f.settle()
        f.panel.keyboardScroll = .oldest; f.panel.keyboardScrollRequest += 1
        try await f.settle()
        #expect(!f.panel.atBottom)
        f.model.draft = "OB1 message after reading earlier history"
        try await f.settle()
        let root = try #require(f.host)
        var visited: Set<ObjectIdentifier> = []
        func findSend(_ object: Any) -> NSObject? {
            guard let node = object as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            func string(_ selector: String) -> String? {
                let name = NSSelectorFromString(selector)
                return node.responds(to: name) ? node.perform(name)?.takeUnretainedValue() as? String : nil
            }
            if string("accessibilityRole") == "AXButton", string("accessibilityLabel") == "Send" { return node }
            let selector = NSSelectorFromString("accessibilityChildren")
            let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
            for child in children + ((node as? NSView)?.subviews ?? []) { if let button = findSend(child) { return button } }
            return nil
        }
        let send = try #require(findSend(root), "Native composer Send button")
        #expect((send as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle()
        #expect(f.cards.cards.last?.body == "OB1 message after reading earlier history")
        if accepted {
            #expect(f.model.draft.isEmpty && f.panel.atBottom)
            try expectNewestVisible(f)
        } else {
            #expect(f.model.draft == "OB1 message after reading earlier history" && !f.panel.atBottom)
        }
    }

    @Test func newShortMessageAfterATallCappedMessageIsRealizedAndFollowed() async throws {
        let f = try Q3ScrollHarness(longNewest: true); defer { f.cleanup() }
        f.mount(); try await f.settle(); f.record("tall-before")
        let before = f.panel.viewportForDiagnostics
        let top = try #require(f.panel.newestMessageTopForDiagnostics)
        #expect(f.panel.atBottom && abs(before.offset - top) < 2)
        #expect(before.contentHeight - before.offset > before.height * 2)
        f.append("New message that should be brought into view.")
        try await f.settle(); f.record("tall-after")
        #expect(f.panel.atBottom)
        try expectNewestVisible(f)
        #expect(f.panel.viewportForDiagnostics.offset > before.offset + before.height)

    }

    @Test func shortBottomRowFollowsAfterNativeLayoutSettles() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        f.mount(); try await f.settle(); f.record("short-before")
        let before = f.panel.viewportForDiagnostics
        #expect(f.panel.atBottom)
        f.append("New short message.")
        try await f.settle(); f.record("short-after")
        try expectNewestVisible(f)
        #expect(f.panel.viewportForDiagnostics.offset > before.offset)

    }

    @Test func replacingActivityAfterACappedLongMessageFollowsTheNewMessage() async throws {
        let f = try Q3ScrollHarness(longNewest: true); defer { f.cleanup() }
        f.messaging.assistantActivity = AssistantActivity(phase: .working, sessionKey: "claude:test", agentName: "Claude", detail: "Drafting", progress: 0.4, since: Date())
        f.mount(); try await f.settle(); f.record("activity-before")
        let before = f.panel.viewportForDiagnostics
        #expect(f.panel.atBottom)
        f.messaging.assistantActivity = nil
        f.append("The completed answer replaces the working row.")
        try await f.settle(); f.record("activity-after")
        try expectNewestVisible(f)
        #expect(f.panel.viewportForDiagnostics.offset > before.offset)
    }

    @Test func openingTheNewestCardFromAPeekKeepsFollowing() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        f.mount(target: f.newestID); try await f.settle(); f.record("peek-open-before")
        let before = f.panel.viewportForDiagnostics
        let top = try #require(f.panel.newestMessageTopForDiagnostics)
        #expect(top < before.offset + before.height) // Latest bubble is already visible.
        #expect(f.panel.atBottom)
        f.append("A reply after opening the most recent peek.")
        try await f.settle(); f.record("peek-open-after")
        #expect(f.panel.atBottom)
        try expectNewestVisible(f)
        #expect(f.panel.viewportForDiagnostics.offset > before.offset)
    }

    @Test func keyboardScrollingToHistoryDeliberatelyStopsFollowing() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        f.mount(); try await f.settle()
        f.panel.keyboardScroll = .line(-1); f.panel.keyboardScrollRequest += 1
        try await f.settle(); f.record("history-before")
        #expect(!f.panel.atBottom)
        let before = f.panel.viewportForDiagnostics.offset
        f.append("Leave the reader in history.")
        try await f.settle(); f.record("history-after")
        #expect(!f.panel.atBottom && abs(f.panel.viewportForDiagnostics.offset - before) < 2)
    }

    @Test func messageArrivingBeforeFirstVisibleOpeningLayoutIsFollowed() async throws {
        let f = try Q3ScrollHarness(longNewest: true); defer { f.cleanup() }
        f.mount(duringOpening: { f.append("Arriving before the first visible layout completes.") })
        try await f.settle(); f.record("during-open")
        #expect(f.panel.atBottom)
        try expectNewestVisible(f)
    }

    @Test func firstNewMessageAfterReopeningACappedThreadIsFollowed() async throws {
        let f = try Q3ScrollHarness(longNewest: true); defer { f.cleanup() }
        f.mount(); try await f.settle()
        f.unmount(); try await f.settle()
        f.mount(); try await f.settle(); f.record("reopen-before")
        let before = f.panel.viewportForDiagnostics.offset
        f.append("The first reply after reopening.")
        try await f.settle(); f.record("reopen-after")
        #expect(f.panel.atBottom)
        try expectNewestVisible(f)
        #expect(f.panel.viewportForDiagnostics.offset > before)
    }

    @Test func newestQuestionOptionsFitAboveTheComposerAfterLayout() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        f.cards.add(Card(kind: .question, body: "Choose how to proceed.",
                         options: [CardOption(id: "go", label: "Continue"), CardOption(id: "skip", label: "Skip")]))
        f.mount(); try await f.settle()
        try expectNewestVisible(f)
    }

    @Test func messageTallerThanOneHundredViewportsBecomesSeenOnlyOnActiveSurface() async throws {
        let f = try Q3ScrollHarness(longNewest: true, newestBody: String(repeating: "Visible line.\n", count: 4000))
        defer { f.cleanup() }
        f.mount(); f.activity.update(suspended: false, avatar: false, conversation: false, peek: false, settings: false)
        try await f.settle()
        let newest = try #require(f.newestID)
        #expect(!f.cards.seenIDs.contains(newest))
        let frame = try #require(f.panel.newestMessageFrameForDiagnostics)
        let viewport = f.panel.viewportForDiagnostics
        #expect(frame.height > viewport.height * 100)
        #expect(frame.minY < viewport.offset + viewport.height && frame.maxY > viewport.offset)
        f.activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        try await f.settle()
        #expect(f.cards.seenIDs.contains(newest))
        #expect(!f.cards.seenIDs.contains(try #require(f.cards.cards.first?.id)))
    }

    /// A tall measured row used to make the jump land where the lazy stack placed no rows, so the
    /// thread showed blank. Whether it did depended on the row height, and so on the display scale.
    @Test(arguments: [(lines: 100, scale: 1.0), (100, 2.0), (4000, 1.0), (4000, 2.0)])
    func openingAVeryTallEarlierMessageShowsTheLatestButtonForExistingUnreadReplies(lines: Int, scale: CGFloat) async throws {
        let f = try Q3ScrollHarness(longNewest: true, newestBody: String(repeating: "Earlier visible line.\n", count: lines), scale: scale)
        defer { f.cleanup() }
        #expect(f.window.backingScaleFactor == scale)
        let earlier = try #require(f.newestID)
        for index in 0..<20 { f.append("Unread reply \(index)") }
        let newest = try #require(f.newestID)
        f.mount(target: earlier); try await f.settle()
        #expect(!f.panel.atBottom && f.cards.seenIDs.contains(earlier))
        #expect(!f.cards.seenIDs.contains(newest))
        #expect(f.panel.latestButtonVisibleForDiagnostics)
        f.panel.keyboardScroll = .latest; f.panel.keyboardScrollRequest += 1
        try await f.settle()
        #expect(f.panel.atBottom && !f.panel.latestButtonVisibleForDiagnostics)
        try expectNewestVisible(f)
    }

    @Test func navigationIntersectionIncludesAnswerRowsWithoutMarkingThemAsAgentCards() {
        let frames = ["answer:q": CGRect(x: 0, y: 0, width: 300, height: 60),
                      "card:huge": CGRect(x: 0, y: 60, width: 300, height: 60000),
                      "card:below": CGRect(x: 0, y: 60060, width: 300, height: 20)]
        let viewport = ConversationViewport(offset: 0, height: 500)
        #expect(ConversationViewportVisibility.visibleIDs(frames: frames, viewport: viewport) == ["answer:q", "card:huge"])
        #expect(ConversationSeenVisibility.visibleIDs(frames: frames, viewport: viewport) == ["card:huge"])
        let answer = ConversationEntry(id: "answer:q", timestamp: Date(), content: .userAnswer(cardID: "q", response: .init(text: "An answer", device: .mac)))
        let card = Card(id: "below", kind: .message, body: "Unread below")
        let entry = ConversationEntry(id: "card:below", timestamp: card.createdAt, content: .agentCard(card))
        #expect(ConversationLayout.unseenBelow(entries: [answer, entry], visible: [answer.id], seen: []) == 1)
    }

    @Test func seenIntersectionUsesPointsAndExcludesOffscreenAndTouchingRows() {
        let frames = ["card:huge": CGRect(x: 0, y: 0, width: 300, height: 60000),
                      "card:before": CGRect(x: 0, y: -100, width: 300, height: 100),
                      "card:after": CGRect(x: 0, y: 500, width: 300, height: 20),
                      "latestMessage": CGRect(x: 0, y: 0, width: 300, height: 60000)]
        #expect(ConversationSeenVisibility.visibleIDs(frames: frames, viewport: .init(offset: 0, height: 500)) == ["card:huge"])
        #expect(ConversationSeenVisibility.visibleIDs(frames: frames, viewport: .init(offset: 0, height: 0)).isEmpty)
    }

    @Test func visibilityTrackingMarksOnlyReadRowsAndKeepsTheNewMessageCount() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        f.mount(); try await f.settle()
        let first = try #require(f.cards.cards.first?.id)
        let middle = f.cards.cards[15].id
        let newest = try #require(f.newestID)
        #expect(f.cards.seenIDs.contains(newest))
        #expect(!f.cards.seenIDs.contains(first) && !f.cards.seenIDs.contains(middle))
        f.panel.keyboardScroll = .oldest; f.panel.keyboardScrollRequest += 1
        try await f.settle()
        #expect(!f.panel.atBottom)
        #expect(f.cards.seenIDs.contains(first))
        #expect(!f.cards.seenIDs.contains(middle))
        let count = ConversationLayout.unseenBelow(entries: f.model.thread, visible: ["card:" + first], seen: f.cards.seenIDs)
        #expect(count > 0)
        f.panel.keyboardScroll = .latest; f.panel.keyboardScrollRequest += 1
        try await f.settle()
        #expect(f.panel.atBottom)
        try expectNewestVisible(f)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JB1_KEYS"] == "1", "Requires an unlocked console; fixture-local focus only."))
    func nativePillsFollowComposerInTabLoop() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        let origin = try #require(f.cards.cards.first?.createdAt)
        f.cards.add(Card(id: "tab-question", kind: .question, body: "Choose", options: [.init(id: "yes", label: "Yes")], createdAt: origin))
        f.model.draft = "A draft"
        f.mount(accessibilityEnabled: true); try await f.settle()
        let host = try #require(f.host)
        (f.window as? Q3OffscreenPanel)?.allowsKey = true
        NSApp.activate(); f.window.makeKey(); try await f.settle()
        try #require(f.window.isKeyWindow && NSApp.isActive)
        let controls = jumpAXNodes(host).filter { node in
            let role = (node as AnyObject).accessibilityRole?()?.rawValue
            return role == "AXButton" || role == "AXTextArea"
        }
        var labels: [String] = []
        for _ in 0..<30 {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: f.window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
            guard let view = f.window.firstResponder as? NSView else { continue }
            let frame = f.window.convertToScreen(view.convert(view.bounds, to: nil))
            let node = controls.first { ($0 as AnyObject).isAccessibilityFocused?() == true } ?? controls.first { node in
                guard let rect = (node as AnyObject).accessibilityFrame?() else { return false }
                return rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            let identifier = node.flatMap { ($0 as AnyObject).accessibilityIdentifier?() }
            let label = node.flatMap { ($0 as AnyObject).accessibilityLabel?() }
            labels.append(identifier.flatMap { $0.isEmpty ? nil : $0 } ?? label ?? "other:\(type(of: view))")
        }
        print("JB1 Tab loop: \(labels)")
        let send = try #require(labels.firstIndex(of: "Send"))
        #expect(labels[(send + 1) % labels.count] == "jump-unread")
        #expect(labels[(send + 2) % labels.count] == "jump-mark-read")
        #expect(labels[(send + 3) % labels.count] == "jump-question")
    }

    @Test func questionPillAndCommandJShareOneCycleAndRequestControlFocus() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        let origin = try #require(f.cards.cards.first?.createdAt)
        for (id, seconds) in [("jump-q1", 1.5), ("jump-q2", 15.5)] {
            f.cards.add(Card(id: id, kind: .question, body: "Choose an option", options: [.init(id: "yes", label: "Yes")], createdAt: origin.addingTimeInterval(seconds)))
        }
        f.cards.markAllSeen()
        f.mount(accessibilityEnabled: true); try await f.settle()
        let host = try #require(f.host)
        let pill = try #require(jumpAXNodes(host).first { node in
            let selector = NSSelectorFromString("accessibilityIdentifier")
            return node.responds(to: selector) && node.perform(selector)?.takeUnretainedValue() as? String == "jump-question"
        })
        #expect((pill as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle()
        #expect(f.panel.scrollTargetCardID == "jump-q1" && f.panel.focusScrollTarget)
        func keyView(_ view: NSView) -> ConversationStripKeys.KeyView? {
            if let key = view as? ConversationStripKeys.KeyView { return key }
            return view.subviews.lazy.compactMap(keyView).first
        }
        let key = try #require(keyView(host))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: f.window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        #expect(key.performKeyEquivalent(with: event))
        try await f.settle()
        #expect(f.panel.scrollTargetCardID == "jump-q2" && f.panel.focusScrollTarget)
    }

    @Test func jumpLatestRemainsAvailableWhenAllHistoryWasAlreadyRead() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        f.cards.markAllSeen()
        f.mount(); try await f.settle()
        #expect(!f.panel.latestButtonVisibleForDiagnostics)
        f.panel.keyboardScroll = .oldest; f.panel.keyboardScrollRequest += 1
        try await f.settle()
        #expect(f.panel.latestButtonVisibleForDiagnostics)
        #expect(!f.panel.atBottom)
        f.panel.keyboardScroll = .latest; f.panel.keyboardScrollRequest += 1
        try await f.settle()
        #expect(!f.panel.latestButtonVisibleForDiagnostics)
        try expectNewestVisible(f)
    }

    @Test func documentViewerReturnsToOriginalChipAndScrollWithoutReadingNewMessages() async throws {
        // Lazy SwiftUI rows expose their AX children only when the app's enhanced AX mode is on.
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber ?? NSNumber(value: false)
        defer { if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: previous, with: "AXEnhancedUserInterface") } }
        if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }

        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        let url = f.root.appendingPathComponent("viewer.md")
        try "# A document\n\nA paragraph to read.".write(to: url, atomically: true, encoding: .utf8)
        let attachment = ZeusProtocol.Attachment(kind: .file, label: "viewer.md", target: url.path, summary: "A document to read in Zeus.")
        let card = Card(id: "viewer-source", kind: .message, body: "Here is the document.", attachments: [attachment], createdAt: Date())
        f.cards.add(card); f.model.draft = "Keep my draft"
        (f.window as? Q3OffscreenPanel)?.allowsKey = true
        f.mount(target: card.id, accessibilityEnabled: true); f.window.makeKey(); try await f.settle()
        let host = try #require(f.host)
        let nodes = jumpAXNodes(host)
        let chip = try #require(nodes.first { ($0 as AnyObject).accessibilityLabel?() == AttachmentChip.accessibilityLabel(attachment) })
        let before = f.panel.viewportForDiagnostics.offset
        #expect((chip as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle()
        #expect(f.panel.document.isOpen && f.panel.document.current?.content?.renderer == .markdown)
        #expect(f.model.draft == "Keep my draft")
        f.append("A new message must stay unread while reading the document.")
        let arrival = try #require(f.newestID)
        try await f.settle()
        #expect(f.panel.document.isOpen && !f.cards.seenIDs.contains(arrival))
        f.panel.document.backRequest += 1
        try await f.settle()
        #expect(!f.panel.document.isOpen)
        #expect(abs(f.panel.viewportForDiagnostics.offset - before) < 2)
        #expect(f.panel.focusedControlForDiagnostics == .init(entryID: "card:viewer-source", controlID: "open:\(attachment.id)"))
        #expect(f.model.draft == "Keep my draft")
    }

    private func expectNewestVisible(_ f: Q3ScrollHarness) throws {
        let scroll = try #require(f.nativeScrollView())
        let frame = try #require(f.panel.newestMessageFrameForDiagnostics)
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        let native = try #require(driver.viewport)
        #expect(frame.minY >= native.offset - 2)
        #expect(frame.maxY <= native.offset + native.height + 2)
        #expect(frame.maxY <= native.contentHeight + 2)
    }

    @Test func jumpToLatestWalksDownFromATallMeasuredRow() {
        let ids = ["a", "tall", "b", "c", "newest"]
        let row = { (y: CGFloat, height: CGFloat) in CGRect(x: 0, y: y, width: 300, height: height) }
        func target(_ frames: [String: CGRect], height: CGFloat = 500, stepping: Bool = false) -> String? {
            ConversationLayout.latestRevealTarget(ids: ids, frames: frames, viewportHeight: height, stepping: stepping)
        }
        // A tall row is measured: step to the row just below the lowest measured row.
        #expect(target(["tall": row(0, 2000)]) == "b")
        #expect(target(["a": row(0, 40), "tall": row(40, 2000)]) == "b")
        // Ordinary rows, or nothing, measured: jump straight to the newest row...
        #expect(target(["b": row(0, 40)]) == "newest")
        #expect(target([:]) == "newest")
        // ...unless the walk has started, since the stack's estimates are still off.
        #expect(target(["b": row(0, 40)], stepping: true) == "c")
        #expect(target([:], stepping: true) == "newest")
        // The newest row is measured: the walk ends there.
        #expect(target(["tall": row(0, 2000), "newest": row(2000, 40)], stepping: true) == "newest")
        // Before the viewport has a height, nothing counts as tall.
        #expect(target(["tall": row(0, 2000)], height: 0) == "newest")
        #expect(ConversationLayout.latestRevealTarget(ids: [], frames: [:], viewportHeight: 500, stepping: false) == nil)
    }

    @Test func exactBottomThresholdAndLongMessageTopCapAreCoveredWithoutSyntheticInputEvents() {
        let viewport = ConversationViewport(offset: 476, contentHeight: 1000, height: 500)
        #expect(ConversationAutoScroll.isPinned(viewport: viewport, newestMessageTop: 900))
        #expect(!ConversationAutoScroll.isPinned(viewport: .init(offset: 475, contentHeight: 1000, height: 500), newestMessageTop: 900))
        #expect(ConversationAutoScroll.isPinned(viewport: .init(offset: 700, contentHeight: 3000, height: 500), newestMessageTop: 700))
    }
}

/// The overnight report: open at the latest, close, let a lot arrive, reopen the next morning.
/// Each open mounts a new thread at the top of its 300-row page, days back, which lays out those
/// oldest rows first. With a row there taller than the viewport, the jump to the newest walked down
/// from it a row at a time and stopped after 60 steps, still days back; otherwise a direct jump
/// could stop short of the newest row.
@Suite(.serialized) @MainActor struct ConversationReopenAtLatestTests {
    /// Rows of every height: one line, a paragraph, and every eighth row taller than the viewport.
    private static func body(_ index: Int, label: String, tall: Int) -> String {
        let lines = [1, 3, 8, 1, 2, tall, 1, 5][index % 8]
        return (0..<lines).map { "\(label) \(index), line \($0): a sentence long enough to wrap in the bubble." }.joined(separator: "\n")
    }
    @discardableResult private func add(_ f: Q3ScrollHarness, count: Int, from start: Date, label: String, tall: Int = 30) -> [String] {
        (0..<count).map { index in
            let card = Card(kind: .message, body: Self.body(index, label: label, tall: tall), createdAt: start.addingTimeInterval(Double(index) * 600))
            f.cards.add(card); f.newestID = card.id
            f.model.noteArrival(card, visible: false, animate: false)
            return card.id
        }
    }
    private func expectShown(_ f: Q3ScrollHarness, _ label: String) throws {
        f.record(label)
        let scroll = try #require(f.nativeScrollView())
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        let native = try #require(driver.viewport)
        let frame = try #require(f.panel.newestMessageFrameForDiagnostics, "\(label): the newest row was never laid out")
        #expect(f.panel.atBottom, "\(label)")
        #expect(frame.minY >= native.offset - 2 && frame.maxY <= native.offset + native.height + 2, "\(label): the newest row is not on screen")
        #expect(native.offset + native.height >= native.contentHeight - 2, "\(label): not at the end of the thread")
    }

    /// The hotkey and "Talk to Zeus" open with no target (`ShellController.openConversation(at: nil)`).
    /// `tall` is every eighth row's line count: about two viewports high, or about thirty.
    @Test(arguments: [0, 40, 400], [30, 400])
    func reopeningAfterArrivalsWhileClosedLandsOnTheNewest(arrivals: Int, tall: Int) async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        let day = 86_400.0
        add(f, count: 250, from: Date().addingTimeInterval(-4 * day), label: "Earlier", tall: tall)
        f.mount(); try await f.settle()
        try expectShown(f, "first open")
        f.unmount(); try await f.settle()
        add(f, count: arrivals, from: Date().addingTimeInterval(-day / 2), label: "Overnight", tall: tall)
        f.mount(); try await f.settle()
        try expectShown(f, "morning open")
    }

    /// Clicking Zeus with unread messages opens at the first one since the person last looked.
    @Test func reopeningAtARecentUnreadCardLandsOnIt() async throws {
        let f = try Q3ScrollHarness(longNewest: false); defer { f.cleanup() }
        let day = 86_400.0
        add(f, count: 250, from: Date().addingTimeInterval(-4 * day), label: "Earlier")
        f.mount(); try await f.settle()
        f.unmount(); try await f.settle()
        let overnight = add(f, count: 400, from: Date().addingTimeInterval(-day / 2), label: "Overnight")
        f.mount(target: overnight[390]); try await f.settle()
        f.record("recent unread")
        let scroll = try #require(f.nativeScrollView())
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        let native = try #require(driver.viewport)
        #expect(native.contentHeight - native.offset < 5000, "the ten newest rows are near the end of the thread")
    }
}
