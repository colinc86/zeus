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
@MainActor private final class FirstClickPress {
    let button: NSObject
    let up: NSEvent
    init(button: NSObject, up: NSEvent) { self.button = button; self.up = up }
    var frame: CGRect? { (button as AnyObject).accessibilityFrame?() }
    func release() { NSApp.postEvent(up, atStart: false) }
}
@Suite(.serialized) @MainActor struct ConversationFirstClickTests {
    @Test(arguments: [false, true], [false, true]) func choiceRespondsToOneHeldPress(tallThread: Bool, typewriter: Bool) async throws {
        try await conversationPress(tallThread: tallThread, live: false, typewriter: typewriter)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FX2_LIVE"] == "1"))
    func liveChoiceWithCliclick() async throws {
        try requireLiveConsole()
        try await conversationPress(tallThread: true, live: true, typewriter: true)
    }
    private func requireLiveConsole() throws {
        let check = Process(), output = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        check.arguments = ["-n", "Root", "-d1"]; check.standardOutput = output
        try check.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); check.waitUntilExit()
        let state = String(decoding: data, as: UTF8.self)
        try #require(state.contains("\"IOConsoleLocked\" = No"), "Live cliclick proof requires an unlocked console; never post into the lock screen")
    }
    private func conversationPress(tallThread: Bool, live: Bool, typewriter: Bool) async throws {
        ZeusFonts.registerBundled()
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previousEnhanced = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber ?? NSNumber(value: false)
        defer { if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: previousEnhanced, with: "AXEnhancedUserInterface") } }
        if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
        let name = TestDefaults.suite("zeus-first-click")
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: FirstClickPasswords())
        settings.typewriterEnabled = typewriter; settings.fontChoice = .system
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let origin = Date().addingTimeInterval(-1000)
        let question = Card(kind: .question, title: "Synthetic first click", body: "Choose a fixture answer.", options: [.init(id: "yes", label: "Fixture Yes")], createdAt: origin.addingTimeInterval(40))
        if tallThread {
            for index in 0..<40 { cards.add(Card(kind: .message, body: "Earlier fixture message \(index). " + String(repeating: "History text. ", count: 10), createdAt: origin.addingTimeInterval(Double(index)))) }
        }
        cards.add(question)
        if tallThread {
            for index in 0..<10 { cards.add(Card(kind: .message, body: "Later fixture message \(index). " + String(repeating: "History text. ", count: 10), createdAt: origin.addingTimeInterval(Double(50 + index)))) }
        }
        #expect(cards.cards.count == (tallThread ? 51 : 1))
        let messaging = FirstClickMessaging(), panel = ConversationPanelState(), activity = SurfaceActivity()
        let model = ConversationModel(cards: cards, messaging: messaging)
        if tallThread { panel.scrollTargetCardID = question.id }
        let host = ConversationHostingView(rootView: ConversationView(settings: settings, store: cards, model: model, messaging: messaging,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity, openSettings: {}, copySetup: {}, resize: { _ in }))
        let window = FirstClickPanel(contentRect: .init(x: -10000, y: -10000, width: 420, height: 650),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.becomesKeyOnlyIfNeeded = true; window.animationBehavior = .none
        defer { panel.isVisible = false; window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host
        if live { window.setFrameOrigin(.init(x: 300, y: 300)); NSApp.activate(); window.makeKeyAndOrderFront(nil) }
        else { window.orderFront(nil) }
        panel.isVisible = true; panel.screenHeight = 900; model.openPanel(viewportManaged: true)
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
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
        if tallThread { window.makeKey() }
        else if !live { #expect(!window.isKeyWindow) }
        let hit = try #require(host.hitTest(host.convert(point, from: nil)))
        print("FX2 click policy: root=\(host.acceptsFirstMouse(for: down)) hit=\(type(of: hit)) accepts=\(hit.acceptsFirstMouse(for: down)) key=\(window.isKeyWindow)")
        #expect(host.acceptsFirstMouse(for: down))
        #expect(host.acceptsFirstMouse(for: nil))
        #expect(hit.acceptsFirstMouse(for: down))
        // App-local events only: the queued up event also supports native tracking loops.
        let press = FirstClickPress(button: button, up: up)
        let offsetBefore = panel.viewportForDiagnostics.offset
        print("FX2 before press tall=\(tallThread) focus=\(String(describing: panel.focusedControlForDiagnostics)) viewport=\(panel.viewportForDiagnostics) offset=\(offsetBefore) frame=\(frame)")
        let midPress = Timer(timeInterval: 0.08, repeats: false) { _ in
            MainActor.assumeIsolated {
                #expect(abs(panel.viewportForDiagnostics.offset - offsetBefore) < 1)
                #expect(press.frame == frame)
                print("FX2 during press tall=\(tallThread) focus=\(String(describing: panel.focusedControlForDiagnostics)) offset=\(panel.viewportForDiagnostics.offset) frame=\(String(describing: press.frame))")
            }
        }
        let release = Timer(timeInterval: 0.12, repeats: false) { _ in
            MainActor.assumeIsolated { press.release() }
        }
        RunLoop.main.add(midPress, forMode: .common)
        if live {
            let screenHeight = try #require(NSScreen.screens.first).frame.height
            let coordinate = "\(Int(frame.midX)),\(Int(screenHeight - frame.midY))"
            let code = try await Task.detached {
                let click = Process()
                click.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cliclick")
                click.arguments = ["dd:" + coordinate, "w:120", "du:" + coordinate]
                try click.run(); click.waitUntilExit(); return click.terminationStatus
            }.value
            #expect(code == 0)
        } else {
            RunLoop.main.add(release, forMode: .common)
            NSApp.sendEvent(down)
        }
        try await Task.sleep(for: .milliseconds(150))
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            if pending.windowNumber == window.windowNumber { NSApp.sendEvent(pending) }
            else { NSApp.postEvent(pending, atStart: true) }
        }
        for _ in 0..<10 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.focusCameFromPointer)

        print("FX2 first response=\(String(describing: cards.card(id: question.id)?.response)) key=\(window.isKeyWindow)")
        #expect(cards.card(id: question.id)?.response?.optionID == "yes")
        #expect(model.revealer(cardID: question.id) == nil, "Question options never sit below a growing typewriter")
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        NSApp.sendEvent(tab)
        #expect(!panel.focusCameFromPointer, "Keyboard navigation restores focus scrolling")
    }
    @Test(arguments: [false, true])
    func peekChoiceAnswersWithoutExpandingDuringHeldPress(typewriter: Bool) async throws {
        try await peekPress(typewriter: typewriter, live: false)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FX2_LIVE"] == "1"))
    func livePeekWithCliclick() async throws {
        try requireLiveConsole()
        try await peekPress(typewriter: true, live: true)
    }
    private func peekPress(typewriter: Bool, live: Bool) async throws {
        ZeusFonts.registerBundled()
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber ?? NSNumber(value: false)
        NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { NSApp.perform(enhanced, with: previous, with: "AXEnhancedUserInterface") }
        let name = TestDefaults.suite("zeus-fx2-peek")
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: FirstClickPasswords())
        settings.typewriterEnabled = typewriter; settings.fontChoice = .system
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let card = Card(kind: .question, body: String(repeating: "A synthetic choice with several lines. ", count: 8),
                        options: [.init(id: "yes", label: "Peek Yes")])
        store.add(card)
        let model = PeekModel(store: store), panel = PeekPanelState(), activity = SurfaceActivity()
        _ = model.receive(card, suppression: .init(), reduceMotion: false, typewriter: typewriter)
        panel.layout = PeekLayout.measure(card: card, font: .system, moreCount: 0, error: nil, answeredOptionID: nil, available: .init(width: 420, height: 650))
        activity.update(suspended: false, avatar: false, conversation: false, peek: true, settings: false)
        var expansions = 0
        let host = PeekHostingView(rootView: PeekView(model: model, panel: panel, settings: settings, activity: activity, open: { _ in expansions += 1 }))
        let window = FirstClickPanel(contentRect: .init(x: live ? 300 : -10000, y: live ? 300 : -10000, width: 420, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        defer { model.close(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host; window.orderFront(nil)
        if live { NSApp.activate() }
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let button = try #require(firstClickNodes(host).first { ($0 as AnyObject).accessibilityLabel?() == "Peek Yes" })
        let frame = try #require((button as AnyObject).accessibilityFrame?())
        let point = window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.12,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let press = FirstClickPress(button: button, up: up)
        let sample = Timer(timeInterval: 0.08, repeats: false) { _ in
            MainActor.assumeIsolated {
                print("FX2 peek midpress typewriter=\(typewriter) frame=\(String(describing: press.frame)) before=\(frame)")
                #expect(press.frame == frame)
            }
        }
        RunLoop.main.add(sample, forMode: .common)
        if live {
            let screenHeight = try #require(NSScreen.screens.first).frame.height
            let coordinate = "\(Int(frame.midX)),\(Int(screenHeight - frame.midY))"
            let code = try await Task.detached {
                let click = Process(); click.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cliclick")
                click.arguments = ["dd:" + coordinate, "w:120", "du:" + coordinate]
                try click.run(); click.waitUntilExit(); return click.terminationStatus
            }.value
            #expect(code == 0)
        } else {
            let release = Timer(timeInterval: 0.12, repeats: false) { _ in MainActor.assumeIsolated { press.release() } }
            RunLoop.main.add(release, forMode: .common)
            NSApp.sendEvent(down)
        }
        try await Task.sleep(for: .milliseconds(150))
        if let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            if event.windowNumber == window.windowNumber { NSApp.sendEvent(event) } else { NSApp.postEvent(event, atStart: true) }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.card(id: card.id)?.response?.optionID == "yes")
        #expect(expansions == 0, "An inline answer must not expand the peek")
    }

}
