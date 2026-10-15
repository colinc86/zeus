import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class FirstClickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private struct FirstClickPasswords: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@MainActor private final class FirstClickMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}
@MainActor private func firstClickNodes(_ root: Any) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        var children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        if node.responds(to: legacy) { children += node.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [Any] ?? [] }
        return [node] + (children + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@Suite(.serialized) @MainActor struct ConversationFirstClickTests {
    @Test func nonKeyChoiceAcceptsAndRespondsToOneMousePair() async throws {
        ZeusFonts.registerBundled()
        try #require(!NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.path == "/Applications/Zeus.app"
        }, "Never exercise a dev panel beside installed Zeus")
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previousEnhanced = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber ?? NSNumber(value: false)
        defer { if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: previousEnhanced, with: "AXEnhancedUserInterface") } }
        if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
        let name = "zeus-first-click-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: FirstClickPasswords())
        settings.typewriterEnabled = false; settings.fontChoice = .system
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let question = Card(kind: .question, title: "Synthetic first click", body: "Choose a fixture answer.", options: [.init(id: "yes", label: "Fixture Yes")])
        cards.add(question)
        let messaging = FirstClickMessaging(), panel = ConversationPanelState(), activity = SurfaceActivity()
        let model = ConversationModel(cards: cards, messaging: messaging)
        let host = ConversationHostingView(rootView: ConversationView(settings: settings, store: cards, model: model, messaging: messaging,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity, openSettings: {}, copySetup: {}, resize: { _ in }))
        let window = FirstClickPanel(contentRect: .init(x: -10000, y: -10000, width: 420, height: 650),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.becomesKeyOnlyIfNeeded = true; window.animationBehavior = .none
        defer { panel.isVisible = false; window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host; window.orderFront(nil)
        panel.isVisible = true; panel.screenHeight = 900; model.openPanel(viewportManaged: true)
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        // Check the SwiftUI click targets exposed by this real panel before resolving the question.
        for node in firstClickNodes(host) where (node as AnyObject).accessibilityRole?() == NSAccessibility.Role.button {
            guard let targetFrame = (node as AnyObject).accessibilityFrame?(), targetFrame.width > 0 else { continue }
            let targetPoint = window.convertPoint(fromScreen: .init(x: targetFrame.midX, y: targetFrame.midY))
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: targetPoint, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(host.acceptsFirstMouse(for: event), "Each hosted control accepts the first click")
        }
        let button = try #require(firstClickNodes(host).first { ($0 as AnyObject).accessibilityLabel?() == "Fixture Yes" })
        let frame = try #require((button as AnyObject).accessibilityFrame?())
        let point = window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: false), with: "AXEnhancedUserInterface") }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(!window.isKeyWindow)
        let hit = try #require(host.hitTest(host.convert(point, from: nil)))
        print("FX2 click policy: root=\(host.acceptsFirstMouse(for: down)) hit=\(type(of: hit)) accepts=\(hit.acceptsFirstMouse(for: down)) key=\(window.isKeyWindow)")
        #expect(host.acceptsFirstMouse(for: down))
        #expect(host.acceptsFirstMouse(for: nil))
        #expect(hit.acceptsFirstMouse(for: down))
        // App-local events only: the queued up event also supports native tracking loops.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            if pending.windowNumber == window.windowNumber { window.sendEvent(pending) }
            else { NSApp.postEvent(pending, atStart: true) }
        }
        for _ in 0..<10 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        print("FX2 first response=\(String(describing: cards.card(id: question.id)?.response)) key=\(window.isKeyWindow)")
        #expect(cards.card(id: question.id)?.response?.optionID == "yes")
    }
}
