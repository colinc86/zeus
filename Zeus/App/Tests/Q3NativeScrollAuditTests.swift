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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Real ConversationView + native NSScrollView. Windows are entirely offscreen, never key,
/// never activated, and no keyboard/mouse input or screen capture is used.
@MainActor private final class Q3ScrollHarness {
    let root: URL
    let suite = "zeus-q3-scroll-\(UUID())"
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

    init(longNewest: Bool, newestBody: String? = nil) throws {
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

    @Test func openingAVeryTallEarlierMessageShowsTheLatestButtonForExistingUnreadReplies() async throws {
        let f = try Q3ScrollHarness(longNewest: true, newestBody: String(repeating: "Earlier visible line.\n", count: 4000))
        defer { f.cleanup() }
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

    private func expectNewestVisible(_ f: Q3ScrollHarness) throws {
        let scroll = try #require(f.nativeScrollView())
        let frame = try #require(f.panel.newestMessageFrameForDiagnostics)
        let driver = ConversationScrollDriver(); driver.scrollView = scroll
        let native = try #require(driver.viewport)
        #expect(frame.minY >= native.offset - 2)
        #expect(frame.maxY <= native.offset + native.height + 2)
        #expect(frame.maxY <= native.contentHeight + 2)
    }

    @Test func exactBottomThresholdAndLongMessageTopCapAreCoveredWithoutSyntheticInputEvents() {
        let viewport = ConversationViewport(offset: 476, contentHeight: 1000, height: 500)
        #expect(ConversationAutoScroll.isPinned(viewport: viewport, newestMessageTop: 900))
        #expect(!ConversationAutoScroll.isPinned(viewport: .init(offset: 475, contentHeight: 1000, height: 500), newestMessageTop: 900))
        #expect(ConversationAutoScroll.isPinned(viewport: .init(offset: 700, contentHeight: 3000, height: 500), newestMessageTop: 700))
    }
}
