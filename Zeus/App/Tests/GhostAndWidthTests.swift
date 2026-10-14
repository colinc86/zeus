import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor
struct GhostAndWidthTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func fadesExactlyAtDeadlineAndAnInteractionRestartsTheDelay() {
        var state = AvatarGhostState()
        let config = AvatarGhostState.Configuration(enabled: true)
        state.update(at: epoch, configuration: config, inputs: .init())
        #expect(state.alpha == 1 && state.nextDeadline == epoch.addingTimeInterval(30))
        state.update(at: epoch.addingTimeInterval(29.999), configuration: config, inputs: .init())
        #expect(state.alpha == 1)
        state.update(at: epoch.addingTimeInterval(30), configuration: config, inputs: .init())
        #expect(state.alpha == 0.3 && state.nextDeadline == nil)
        state.update(at: epoch.addingTimeInterval(60), configuration: config, inputs: .init(), interaction: true)
        #expect(state.alpha == 1 && state.nextDeadline == epoch.addingTimeInterval(90))
    }

    @Test(arguments: ["hidden", "panel", "peek", "hover", "question", "work"])
    func inhibitedStatesWakeTheAvatarAndDoNotScheduleAFade(reason: String) {
        var state = AvatarGhostState()
        let config = AvatarGhostState.Configuration(enabled: true)
        state.update(at: epoch, configuration: config, inputs: .init())
        state.update(at: epoch.addingTimeInterval(30), configuration: config, inputs: .init())
        var input = AvatarGhostState.Inputs()
        switch reason {
        case "hidden": input.visible = false
        case "panel": input.panelOpen = true
        case "peek": input.peekVisible = true
        case "hover": input.hovered = true
        case "question": input.questionWaiting = true
        default: input.assistantBusy = true
        }
        state.update(at: epoch.addingTimeInterval(60), configuration: config, inputs: input)
        #expect(state.alpha == 1 && state.nextDeadline == nil)
        state.update(at: epoch.addingTimeInterval(600), configuration: config, inputs: input)
        #expect(state.alpha == 1 && state.nextDeadline == nil)
        state.update(at: epoch.addingTimeInterval(700), configuration: config, inputs: .init())
        #expect(state.alpha == 1 && state.nextDeadline == epoch.addingTimeInterval(730))
    }

    @Test func disablingOrEditingGhostSettingsRestoresFullOpacityAndMotionIsOptional() {
        var state = AvatarGhostState(), config = AvatarGhostState.Configuration(enabled: true)
        state.update(at: epoch, configuration: config, inputs: .init())
        state.update(at: epoch.addingTimeInterval(30), configuration: config, inputs: .init())
        config.opacity = 0.7
        state.update(at: epoch.addingTimeInterval(40), configuration: config, inputs: .init())
        #expect(state.alpha == 1 && state.nextDeadline == epoch.addingTimeInterval(70))
        state.update(at: epoch.addingTimeInterval(70), configuration: config, inputs: .init())
        #expect(state.alpha == 0.7)
        config.enabled = false
        state.update(at: epoch.addingTimeInterval(80), configuration: config, inputs: .init())
        #expect(state.alpha == 1 && state.nextDeadline == nil)
        #expect(AvatarGhostState.animationDuration(reduceMotion: true) == 0)
        #expect(AvatarGhostState.animationDuration(reduceMotion: false) > 0)
    }

    @Test func movingTheWallClockBackwardDoesNotStrandAnIdleDeadline() {
        var state = AvatarGhostState()
        let config = AvatarGhostState.Configuration(enabled: true)
        state.update(at: epoch, configuration: config, inputs: .init())
        state.update(at: epoch.addingTimeInterval(-3600), configuration: config, inputs: .init())
        #expect(state.nextDeadline == epoch.addingTimeInterval(-3570))
        state.update(at: epoch.addingTimeInterval(-3570), configuration: config, inputs: .init())
        #expect(state.alpha == 0.3 && state.nextDeadline == nil)
    }

    @Test func settingsPersistAndRejectInvalidSavedOrEditedNumbers() throws {
        let suite = "zeus-w1-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(!settings.fadeZeusWhenIdle && settings.idleOpacity == 0.3 && settings.idleFadeDelay == 30)
        #expect(settings.conversationWidth == Double(ConversationWidth.minimum))
        settings.fadeZeusWhenIdle = true; settings.idleOpacity = 0.67; settings.idleFadeDelay = 600
        settings.conversationWidth = 551.4
        let restored = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(restored.fadeZeusWhenIdle && restored.idleOpacity == 0.67 && restored.idleFadeDelay == 600)
        #expect(restored.conversationWidth == 551)
        settings.idleOpacity = 0; settings.idleFadeDelay = 900; settings.conversationWidth = .nan
        #expect(settings.idleOpacity == 0.1 && settings.idleFadeDelay == 600 && settings.conversationWidth == Double(ConversationWidth.minimum))
        defaults.set(Double.nan, forKey: "avatar.ghost.opacity")
        defaults.set(-1.0, forKey: "avatar.ghost.delay")
        defaults.set(Double.infinity, forKey: "conversation.width")
        let invalid = AppSettings(defaults: defaults, userDirectory: nil)
        #expect(invalid.idleOpacity == 0.3 && invalid.idleFadeDelay == 5 && invalid.conversationWidth == Double(ConversationWidth.minimum))
    }

    @Test func widthBoundsGridAndAwayEdgeFollowTheScreenAndAvatar() {
        #expect(ConversationWidth.clamp(10, screenWidth: 1440) == ConversationWidth.minimum)
        #expect(ConversationWidth.clamp(900, screenWidth: 1440) == 720)
        #expect(ConversationWidth.clamp(551.6, screenWidth: 1440) == 552)
        #expect(ConversationWidth.clamp(700, screenWidth: 1000) == 500)
        #expect(ConversationWidth.clamp(700, screenWidth: 600) == 300)
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let panel = CGRect(x: -400, y: 100, width: 380, height: 400)
        #expect(ConversationWidth.edge(avatarX: -100, panel: panel, screen: screen) == .left)
        #expect(ConversationWidth.edge(avatarX: -450, panel: panel, screen: screen) == .right)
        #expect(ConversationWidth.dragged(startWidth: 380, delta: -100.4, edge: .left) == 480)
        #expect(ConversationWidth.dragged(startWidth: 380, delta: 100.4, edge: .right) == 480)
        #expect(ConversationWidth.origin(fixedX: -100, width: 600, edge: .left, screen: screen) == -700)
        #expect(ConversationWidth.origin(fixedX: -900, width: 600, edge: .right, screen: screen) == -900)
        #expect(ConversationWidth.bubble(panelWidth: 600, user: false) == 536)
        #expect(ConversationWidth.bubble(panelWidth: 600, user: true) == 492)
    }

    @Test func nativeEdgeDragEmitsWholeWidthsAndHoverDoesNotMakeClicksPassThrough() throws {
        let handle = ConversationResizeHandle()
        var widths: [CGFloat] = []
        handle.onResize = { width, _ in widths.append(width) }
        handle.edge = .left; handle.beginDrag(at: 200, width: 380)
        handle.drag(to: 100.2); handle.drag(to: 90.7)
        #expect(widths == [480, 489])
        let suite = "zeus-w1-hover-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), settings = AppSettings(defaults: defaults, userDirectory: nil)
        let view = AvatarInteractionView(rootView: SpriteAvatarView(settings: settings, status: AvatarStatusModel(cards: cards),
            messaging: AgentMessagingHub(), artLayout: AvatarArtLayout(), activity: SurfaceActivity()))
        view.frame = CGRect(x: 0, y: 0, width: 96, height: 112)
        var hover: [Bool] = [], clicks = 0
        view.onHover = { hover.append($0) }; view.onClick = { clicks += 1 }
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: event); view.mouseExited(with: event)
        #expect(hover == [true, false] && view.hitTest(CGPoint(x: 10, y: 10)) === view)
        #expect(view.accessibilityPerformPress() && clicks == 1)
    }

    @Test func nativePanelResizesWithoutReplacingDraftAndRendersGhostSettings() async throws {
        let suite = "zeus-w1-render-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.typewriterEnabled = false; settings.fadeZeusWhenIdle = true
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging = AgentMessagingHub()
        messaging.previewEnabled = true
        let body = String(repeating: "A wider conversation gives your messages room to breathe. Whole points keep the pixel frame crisp. Unicode works too: café, 日本語, 👋. ", count: 6)
        cards.add(Card(kind: .message, title: "Room to read", body: body))
        let model = ConversationModel(cards: cards, messaging: messaging)
        model.draft = "Keep this unfinished draft while resizing."
        let panel = ConversationPanelState(), activity = SurfaceActivity()
        panel.isVisible = true; panel.tail = .init(edge: .bottom, offset: 300)
        model.openPanel(viewportManaged: true)
        let window = GhostWidthFixturePanel(contentRect: CGRect(x: -20000, y: -20000, width: 380, height: 600),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        defer { panel.isVisible = false; window.orderOut(nil); window.contentView = nil; window.close() }
        let host = ConversationHostingView(rootView: ConversationView(settings: settings, store: cards, model: model, messaging: messaging,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity, openSettings: {}, copySetup: {}, resize: { _ in }))
        host.sizingOptions = []
        window.contentView = host; window.orderFront(nil)
        var heights: [CGFloat] = []
        for width in [CGFloat(380), 600] {
            panel.width = width; window.setContentSize(CGSize(width: width, height: 600))
            for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(host.bounds.width == width && model.draft == "Keep this unfinished draft while resizing.")
            heights.append(try #require(panel.newestMessageFrameForDiagnostics?.height))
            #expect(host.hitTest(CGPoint(x: 2, y: 20)) === host.resizeHandle)
            try writeRender(host, name: "panel-\(Int(width))")
        }
        #expect(heights[1] < heights[0], "Widening must reflow the bubble, not just add blank panel space")
        let settingsHost = NSHostingView(rootView: CharacterSettingsView(settings: settings, resetPosition: {})
            .padding(24).frame(width: 572).buttonStyle(ZeusButtonStyle(.secondary, size: .small))
            .toggleStyle(ZeusCheckboxStyle()).environment(\.zeusFontChoice, .system).environment(\.zeusAnimationsActive, false))
        window.contentView = settingsHost
        window.setContentSize(CGSize(width: 572, height: 780))
        for _ in 0..<10 { settingsHost.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        try writeRender(settingsHost, name: "character-ghost")
    }

    private func writeRender(_ view: NSView, name: String) throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }
        let directory = repo.appendingPathComponent("build/w1-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@MainActor private final class GhostWidthFixturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
