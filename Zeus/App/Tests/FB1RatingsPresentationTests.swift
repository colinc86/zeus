import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private func fb1Nodes(_ root: Any) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    func walk(_ value: Any) -> [NSObject] {
        guard let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
        return [node] + (children + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func fb1Label(_ node: NSObject) -> String {
    for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector), let text = node.perform(selector)?.takeUnretainedValue() as? String, !text.isEmpty { return text }
    }
    return ""
}
@MainActor private final class FB1Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private final class FB1MouseRelease {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
    func post() { NSApp.postEvent(event, atStart: false) }
}
@MainActor private struct FB1Passwords: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@MainActor @Suite(.serialized) struct FB1RatingsPresentationTests {
    private func mount<V: View>(_ view: V, width: CGFloat = 400, height: CGFloat = 320,
                                theme: ZeusThemeDefinition = .classic, scheme: ColorScheme = .dark, font: ZeusFontChoice = .pixel) async throws -> (TestHostingView, NSWindow) {
        ZeusFonts.registerBundled()
        let effective = theme.fixedAppearance ?? scheme
        let host = TestHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
            .environment(\.zeusTheme, theme).environment(\.zeusFontChoice, font).environment(\.colorScheme, effective)
            .environment(\.zeusAnimationsActive, false).environment(\.accessibilityEnabled, true)
            .background(theme.palette(for: effective).panel).zeusThemeAppearance(theme))
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: effective == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        return (host, window)
    }
    @Test func firstRatingPressOpensInlineChoicesAndVoiceOverActionsExist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb1-ax-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let model = MessageRatingsModel(cards: cards, source: { fake }), card = FB1RatingsTests.card()
        cards.add(card)
        let (host, window) = try await mount(FB1RatingFixture(card: card, model: model, hover: true).padding(16))
        defer { window.contentView = nil; window.close() }
        let button = try #require(fb1Nodes(host).first { fb1Label($0) == "Rate this kind of message (⌘R)" }, "AX labels: \(fb1Nodes(host).map(fb1Label))")
        #expect((button as AnyObject).accessibilityPerformPress?() == true)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let nodes = fb1Nodes(host), labels = nodes.map(fb1Label)
        #expect(model.drafts[card.id] != nil)
        for label in ["More like this", "Neutral", "Stop these", "Edit the kind label", "Rate this message only"] { #expect(labels.contains(label), "Missing \(label): \(labels)") }
        let actions = nodes.flatMap { node -> [NSAccessibilityCustomAction] in
            let selector = NSSelectorFromString("accessibilityCustomActions")
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? [] : []
        }
        #expect(actions.contains { $0.name == "Rate: stop these" })
        let neutral = try #require(nodes.first { fb1Label($0) == "Neutral" })
        #expect((neutral as AnyObject).accessibilityPerformPress?() == true)
        for _ in 0..<4 { await Task.yield() }
        #expect(fake.ratings.first?.rating == .neutral)
    }
    @Test func compactRowFitsChoicesAndScopeOnAShortSurface() async throws {
        let cards = CardStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/cards.json"))
        let fake = FB1RatingsFake(), card = FB1RatingsTests.card(), model = MessageRatingsModel(cards: cards, source: { fake })
        model.begin(card)
        let (host, window) = try await mount(MessageRatingInline(card: card, model: model).padding(12), width: 280, height: 240)
        defer { window.contentView = nil; window.close() }
        for label in ["More like this", "Neutral", "Stop these", "Rate this message only"] {
            let node = try #require(fb1Nodes(host).first { fb1Label($0) == label })
            let frame = try #require((node as AnyObject).accessibilityFrame?())
            #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(host.convert(window.convertFromScreen(frame), from: nil)))
        }
    }
    @Test func productionThreadFirstClickAndKeyboardToggle() async throws {
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber ?? NSNumber(value: false)
        NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { NSApp.perform(enhanced, with: previous, with: "AXEnhancedUserInterface") }
        let name = TestDefaults.suite("fb1-keys"), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: FB1Passwords())
        settings.typewriterEnabled = false; settings.fontChoice = .system
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let rating = MessageRatingsModel(cards: cards, source: { fake }), card = FB1RatingsTests.card()
        cards.add(card)
        let messaging = AgentMessagingHub(), panel = ConversationPanelState(), activity = SurfaceActivity()
        let conversation = ConversationModel(cards: cards, messaging: messaging)
        let host = ConversationHostingView(rootView: ConversationView(settings: settings, store: cards, model: conversation,
            messaging: messaging, status: AvatarStatusModel(cards: cards), panel: panel, activity: activity,
            openSettings: {}, copySetup: {}, resize: { _ in }, ratings: rating))
        let window = FB1Panel(contentRect: .init(x: -20000, y: -20000, width: 420, height: 650),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
        defer { panel.isVisible = false; window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFront(nil); panel.isVisible = true; panel.screenHeight = 900
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        func settle() async throws {
            for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        try await settle()
        let button = try #require(fb1Nodes(host).first { fb1Label($0) == "Rate this kind of message (⌘R)" }, "AX labels: \(fb1Nodes(host).map(fb1Label))")
        let frame = try #require((button as AnyObject).accessibilityFrame?())
        let point = window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        #expect(host.acceptsFirstMouse(for: down))
        let mouseRelease = FB1MouseRelease(up)
        let release = Timer(timeInterval: 0.12, repeats: false) { _ in MainActor.assumeIsolated { mouseRelease.post() } }
        RunLoop.main.add(release, forMode: .common); NSApp.sendEvent(down)
        try await settle()
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            if pending.windowNumber == window.windowNumber { NSApp.sendEvent(pending) }
            else { NSApp.postEvent(pending, atStart: true) }
        }
        #expect(rating.drafts[card.id] != nil, "One native press opens the row")
        window.makeKey()
        func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 2,
                windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            if modifiers.contains(.command) { #expect(window.performKeyEquivalent(with: event)) }
            else { NSApp.sendEvent(event) }
        }
        try key("r", code: 15, modifiers: .command); try await settle()
        #expect(rating.drafts.isEmpty, "Command-R again closes the open row")
        try key("r", code: 15, modifiers: .command); try await settle()
        #expect(rating.drafts[card.id] != nil)
        for _ in 0..<3 { try key("\u{f703}", code: 124); try await settle() }
        try key("\r", code: 36); try await settle()
        #expect(rating.drafts[card.id]?.editingLabel == true, "Arrows move from the three choices to Edit; Return activates it")
        #expect(window.firstResponder is NSTextView, "Edit transfers native focus into the text editor")
        rating.setLabel("Discard this edit", id: card.id)
        try key("\u{1b}", code: 53); try await settle()
        #expect(rating.drafts[card.id]?.label == "On-call reminders" && rating.drafts[card.id]?.editingLabel == false)
        try key("\u{1b}", code: 53); try await settle()
        #expect(rating.drafts.isEmpty && panel.isVisible, "Escape closes only the rating row")
        try key("r", code: 15, modifiers: .command); try await settle()
        try key("\r", code: 36); try await settle()
        #expect(fake.ratings.first?.rating == .up, "Opening the row focuses More like this; Return picks it")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_FB1_RENDER"] == "1" || ProcessInfo.processInfo.environment["FB1_RENDER"] == "1"))
    func ratingFixtures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb1-renders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let model = MessageRatingsModel(cards: cards, source: { fake }), card = FB1RatingsTests.card()
        cards.add(card)
        for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
            for scheme in [ColorScheme.light, .dark] {
                for font in [ZeusFontChoice.pixel, .system] {
                    let prefix = theme.id + (scheme == .light ? "-light" : "-dark") + (font == .pixel ? "-pixel" : "-system")
                    model.begin(card)
                    try await render(FB1RatingFixture(card: card, model: model, hover: true, visual: .open).padding(16), prefix + "-inline", theme: theme, scheme: scheme, font: font, width: 400, height: 300)
                    guard theme.id == "classic" else { continue }
                    model.cancel(card.id)
                    for state in [FB1AffordanceState.rest, .discovery, .bubbleHover, .glyphHover, .focused] {
                        try await render(FB1RatingFixture(card: card, model: model, hover: false, visual: state).padding(16), prefix + "-" + state.rawValue, theme: theme, scheme: scheme, font: font, width: 400, height: 170)
                    }
                    for value in MessageRatingValue.allCases {
                        model.begin(card); await model.rate(value, card: card)
                        try await render(FB1RatingFixture(card: card, model: model, hover: false, visual: .rest).padding(16), prefix + "-" + value.rawValue, theme: theme, scheme: scheme, font: font, width: 400, height: 230)
                    }
                    var held = FB1RatingsTests.card("held")
                    for engine in ["exact", "on-device model"] {
                        held.muteDecision = .init(ratingID: "held-kind", kindLabel: "On-call reminders", reason: "looks like On-call reminders", engine: engine, score: 0.82, threshold: 0.8, decidedAt: .now)
                        fake.mutedDecisions[held.id] = held.muteDecision
                        model.show(held.id)
                        try await render(VStack(alignment: .leading, spacing: 20) {
                            MutedMessageLine(card: held, model: model)
                            FB1RatingFixture(card: held, model: model, hover: false)
                            MutedMessageReason(card: held, model: model)
                        }.padding(16), prefix + "-muted-" + engine, theme: theme, scheme: scheme, font: font, width: 400, height: 310)
                    }
                    fake.ratings = MessageRatingValue.allCases.enumerated().map { index, value in
                        .init(id: "settings-\(index)", kindLabel: ["Meeting prep notes", "Service alerts", "On-call reminders"][index], kindKey: "kind-\(index)", rating: value, scope: .kind, exampleCardID: "example-\(index)", exampleText: "A short, redacted example from your assistant.", createdAt: .now, updatedAt: .now)
                    }
                    fake.mutedToday = [held.id]
                    try await render(MessageRatingsSettingsView(model: model).buttonStyle(ZeusButtonStyle(.secondary, size: .small)).padding(24), prefix + "-settings", theme: theme, scheme: scheme, font: .system, width: 700, height: 780)
                    fake.ratings = []
                    try await render(MessageRatingsSettingsView(model: model).buttonStyle(ZeusButtonStyle(.secondary, size: .small)).padding(24), prefix + "-empty", theme: theme, scheme: scheme, font: .system, width: 700, height: 270)
                    try await render(ConversationNoticeLine(notice: .init(kind: .messageRating, createdAt: .now, summary: "Getting a lot of On-call reminders", actionTitle: "Rate them", secondaryTitle: "Not now"), maxWidth: 360, hasAction: true, perform: {}, hasSecondaryAction: true).padding(16), prefix + "-suggestion", theme: theme, scheme: scheme, font: font, width: 400, height: 110)
                }
            }
        }
    }
    private func render<V: View>(_ view: V, _ name: String, theme: ZeusThemeDefinition, scheme: ColorScheme, font: ZeusFontChoice, width: CGFloat, height: CGFloat) async throws {
        let (host, window) = try await mount(view, width: width, height: height, theme: theme, scheme: scheme, font: font)
        defer { window.contentView = nil; window.close() }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/fb1-renders"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: Int(height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
    }
}
private enum FB1AffordanceState: String { case rest, discovery, bubbleHover = "bubble-hover", glyphHover = "glyph-hover", focused, open }
private struct FB1RatingFixture: View {
    let card: Card
    let model: MessageRatingsModel
    let hover: Bool
    var visual: FB1AffordanceState? = nil
    var body: some View {
        ZeusBubble(.agent, muted: model.isHeld(card), maxWidth: 368) {
            HStack {
                Text(card.title ?? "").zeusFont(.button)
                Spacer()
                Text("21:40").zeusFont(.caption)
                if !model.isHeld(card) {
                    if let visual { MessageRatingAffordance(visible: visual != .rest, highlighted: [.glyphHover, .focused, .open].contains(visual), focused: visual == .focused) }
                    else { MessageRatingButton(card: card, model: model, hovered: hover) }
                }
            }
            Text(card.body).zeusFont(.body)
            MessageRatingInline(card: card, model: model)
        }.modifier(MessageRatingAccessibility(card: card, model: model)).accessibilityElement(children: .contain)
    }
}
