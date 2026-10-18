// Q2 visual-audit harness (designer). NOT part of the app's test suite.
// scripts/design-harness/render.sh copies this file into Zeus/App/Tests, runs only this suite, and removes it again.
// It renders every app surface into offscreen, borderless windows parked far off-screen (no screen capture)
// and writes PNGs (2x) to build/q2-renders/, plus text dumps of menus and the accessibility tree.

import AppKit
import Observation
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
import ZeusSprites
@testable import Zeus

@MainActor @Observable private final class AuditMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var deliveryIssue: DeliveryIssue?
    var assistantActivity: AssistantActivity?
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
    func retryPendingDeliveries() {}
    func discardPendingDeliveries() {}

    nonisolated static let claude = ConnectedSession(id: UUID(), sessionKey: "claude:/Users/alex/Projects/Website", agent: .claude, cwd: "/Users/alex/Projects/Website",
                                         clientName: "Claude Code", supportsChannel: true, tmuxPane: nil, connectedAt: Date(timeIntervalSince1970: 1_791_000_000))
    nonisolated static let codex = ConnectedSession(id: UUID(), sessionKey: "codex:/Users/alex/Projects/Website#%3", agent: .codex, cwd: "/Users/alex/Projects/Website",
                                        clientName: "Codex", supportsChannel: false, tmuxPane: "%3", connectedAt: Date(timeIntervalSince1970: 1_790_999_000))
}


/// M4-QA: a managed-session controller with platform's real permission modes and a settable status.
@MainActor @Observable private final class AuditManagedController: ManagedSessionControlling {
    var managedStatus: ManagedSessionStatus = .off
    var missingTmux = false
    /// README renders: every agent installed.
    var allInstalled = false
    var managedTmuxSessionName: String? { managedStatus == .off ? nil : "zeus" }
    var managedAttachCommand: String? { managedTmuxSessionName.map { ZeusManagedCopy.attachCommand(session: $0) } }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        agent == .opencode && !allInstalled ? [] : ManagedAgentLaunch.policies(for: agent).map(\.mode)
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? {
        if missingTmux { return "Not installed: tmux (brew install tmux). Install it, then press Check Again." }
        if allInstalled { return nil }
        return agent == .opencode ? "Not installed: OpenCode (the opencode command). Install it, then press Check Again." : nil
    }
    func startManagedSession() {}
    func stopManagedSession() {}
    func restartManagedSession() {}
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
}

@MainActor private enum Snap {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// A one-off audit may point this under build/tmp/<task>/ for its own run (TEAM.md, build output hygiene).
    static var out = repo.appendingPathComponent("build/q2-renders")
    static var log: [String] = []

    struct Look: CustomStringConvertible {
        let appearance: NSAppearance.Name
        let font: ZeusFontChoice
        var description: String {
            let a: String = switch appearance {
            case .darkAqua: "dark"
            case .accessibilityHighContrastAqua: "light-hc"
            case .accessibilityHighContrastDarkAqua: "dark-hc"
            default: "light"
            }
            return "\(a)-\(font == .pixel ? "pixel" : "sfmono")"
        }
        var isDark: Bool { appearance == .darkAqua || appearance == .accessibilityHighContrastDarkAqua }
        var isHighContrast: Bool { appearance == .accessibilityHighContrastAqua || appearance == .accessibilityHighContrastDarkAqua }
        static let all: [Look] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
            .flatMap { a in [ZeusFontChoice.pixel, .system].map { Look(appearance: a, font: $0) } }
        static let basic: [Look] = [.aqua, .darkAqua].map { Look(appearance: $0, font: .pixel) }
    }

    /// A desktop-ish backdrop so translucent chrome reads as it would over a wallpaper.
    static func backdrop(_ dark: Bool) -> Color { dark ? Color(hex: 0x2E3440) : Color(hex: 0xC9D3E0) }

    @discardableResult
    static func render<V: View>(_ name: String, look: Look, padding: CGFloat = 16, size: CGSize? = nil,
                                settle: Double = 0.35, prepare: ((NSWindow) -> Void)? = nil, @ViewBuilder _ view: () -> V) async throws -> NSView {
        // NSAppearance's high-contrast names don't set SwiftUI's colorSchemeContrast (it follows the system
        // setting), so inject it for the Increase Contrast looks.
        let root = view().padding(padding).background(backdrop(look.isDark))
            .environment(\._colorSchemeContrast, look.isHighContrast ? .increased : .standard)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: -24000, y: -24000, width: size?.width ?? 800, height: size?.height ?? 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look.appearance)
        window.contentView = host
        prepare?(window)
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(settle))
        if size == nil { window.setContentSize(host.fittingSize) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(settle))
        if size == nil { window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .seconds(0.1)) }
        try write(host, name: "\(name)__\(look)")
        window.orderOut(nil)
        return host
    }

    static func write(_ view: NSView, name: String) throws {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        log.append("\(name): \(Int(bounds.width))x\(Int(bounds.height)) pt")
    }

    static func dump(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try text.write(to: out.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    /// The accessibility tree as VoiceOver sees it (role, label, value, children).
    static func axTree(_ element: Any, depth: Int = 0, into lines: inout [String]) {
        guard depth < 40, let node = element as? NSAccessibilityElementProtocol & NSObjectProtocol else { return }
        let object = node as AnyObject
        let role = (object.accessibilityRole?() ?? nil)?.rawValue ?? "?"
        let label = (object.accessibilityLabel?() ?? nil) ?? ""
        let title = (object.accessibilityTitle?() ?? nil) ?? ""
        let value = (object.accessibilityValue?() ?? nil).map { "\($0)" } ?? ""
        let help = (object.accessibilityHelp?() ?? nil) ?? ""
        let isElement = object.isAccessibilityElement?() ?? false
        if isElement || !label.isEmpty || !title.isEmpty {
            let selected = object.isAccessibilitySelected?() ?? false
            lines.append(String(repeating: "  ", count: depth) + "[\(role)] label=\"\(label)\" title=\"\(title)\" value=\"\(value)\"" + (help.isEmpty ? "" : " help=\"\(help)\"") + (selected ? " selected" : ""))
        }
        for child in (object.accessibilityChildren?() ?? nil) ?? [] { axTree(child, depth: depth + 1, into: &lines) }
    }
}

@MainActor private final class AuditActivitySource: ActivityEventSource {
    func start(_ handler: @escaping @MainActor (ActivitySignal) -> Void) {}
    func stop() {}
    var secondsSinceLastInput: TimeInterval { 0 }
    var frontmostApp: (bundleID: String?, name: String?)? { nil }
    var displayCount: Int { 1 }
}

@MainActor private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-q2-\(UUID())")
    let defaults: UserDefaults
    let suite = "zeus-q2-\(UUID())"
    let store: CardStore
    let settings: AppSettings
    let messaging = AuditMessaging()
    let model: ConversationModel
    let status: AvatarStatusModel
    let panel = ConversationPanelState()
    let activity = SurfaceActivity()

    init(font: ZeusFontChoice) {
        defaults = UserDefaults(suiteName: suite) ?? .standard
        store = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.fontChoice = font
        model = ConversationModel(cards: store, messaging: messaging)
        status = AvatarStatusModel(cards: store)
        panel.isVisible = true
        panel.tail = ZeusDialogTail(edge: .bottom, offset: 260)
    }
    deinit { }
    func cleanup() { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }

    func conversation() -> some View {
        ConversationView(settings: settings, store: store, model: model, messaging: messaging, status: status, panel: panel,
                         activity: activity, openSettings: {}, copySetup: {}, resize: { _ in })
    }
}

private let t0 = Date(timeIntervalSince1970: 1_791_100_000) // a fixed afternoon

@MainActor private func longThread(_ f: Fixture) {
    let s1 = AuditMessaging.claude.sessionKey, s2 = AuditMessaging.codex.sessionKey
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    f.store.add(Card(id: "c_m1", kind: .message, title: "Good morning", body: "I looked over your calendar. You have **three meetings** today and the design review moved to 3 PM.", sessionKey: s1, createdAt: at(-1500), updatedAt: at(-1500)))
    f.store.add(Card(id: "u_1", kind: .userMessage, body: "Thanks! Can you draft the agenda for the review?", createdAt: at(-1490), updatedAt: at(-1490)))
    f.store.add(Card(id: "c_q1", kind: .question, title: "Agenda length", body: "Should the agenda cover the whole quarter or just this sprint?",
                     options: [CardOption(id: "q", label: "Whole quarter", style: .primary), CardOption(id: "s", label: "This sprint")], sessionKey: s1,
                     createdAt: at(-1480), updatedAt: at(-1480), status: .answered,
                     response: CardResponse(optionID: "s", optionLabel: "This sprint", respondedAt: at(-1478), device: .mac)))
    f.store.add(Card(id: "c_x1", kind: .message, title: "Old reminder", body: "Stand-up starts in 5 minutes.", sessionKey: s1, createdAt: at(-1470), updatedAt: at(-1470), status: .dismissed))
    f.store.add(Card(id: "c_c1", kind: .content, title: "Agenda draft", body: "Here's the draft agenda and the deck it references.",
                     options: [CardOption(id: "ok", label: "Looks good", style: .primary), CardOption(id: "rev", label: "Revise")],
                     attachments: [Attachment(kind: .file, label: "Design review agenda.md", target: "/Users/alex/Documents/Design review agenda.md"),
                                   Attachment(kind: .folder, label: "Q3 deck", target: "/Users/alex/Documents/Presentations/Q3/very/deep/folder/structure"),
                                   Attachment(kind: .url, label: "Figma: Onboarding flow v3 with a long title", target: "https://www.figma.com/file/abc123/onboarding-flow-v3")],
                     sessionKey: s1, createdAt: at(-10), updatedAt: at(-10)))
    f.store.add(Card(id: "c_p1", kind: .progress, title: "Running the test suite", body: "Running the test suite", progress: 0.62, sessionKey: s2, createdAt: at(-8), updatedAt: at(-8)))
    f.store.add(Card(id: "c_m2", kind: .message, body: "Tests passed: 412 of 412. The build is ready to ship whenever you are.", sessionKey: s2, createdAt: at(-7), updatedAt: at(-7)))
    f.store.add(Card(id: "u_2", kind: .userMessage, body: "Ship it 🚀", createdAt: at(-6), updatedAt: at(-6)))
    f.store.add(Card(id: "c_q2", kind: .question, title: "Release notes", body: "Do you want me to write release notes, or reuse last week's template? You can also tell me what to highlight.",
                     options: [CardOption(id: "w", label: "Write new", style: .primary), CardOption(id: "r", label: "Reuse template"), CardOption(id: "x", label: "Skip", style: .destructive)],
                     input: InputSpec(placeholder: "What should I highlight?"), sessionKey: s1, createdAt: at(-1), updatedAt: at(-1)))
    f.messaging.sessions = [AuditMessaging.claude, AuditMessaging.codex]
}

@MainActor @Suite(.serialized) struct DesignerAuditRenders {
    init() { _ = ZeusFonts.registerBundled() }

    @Test func conversationPanel() async throws {
        for look in Snap.Look.all {
            // Empty: no sessions, no cards.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                try await Snap.render("panel-empty", look: look) { f.conversation() }
            }
            // Empty but connected.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                f.messaging.sessions = [AuditMessaging.claude]
                try await Snap.render("panel-empty-connected", look: look) { f.conversation() }
            }
            // First run: the welcome card.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                f.store.add(WelcomeCard.make(now: t0))
                try await Snap.render("panel-welcome", look: look) { f.conversation() }
            }
            // A long, mixed thread pinned to the latest message, with the reply chip armed.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                longThread(f)
                try await Snap.render("panel-thread", look: look, settle: 0.6) { f.conversation() }
            }
            // Typing row (working + progress) at the bottom of a thread.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                longThread(f)
                f.store.respond(id: "c_q2", response: CardResponse(optionID: "w", optionLabel: "Write new", respondedAt: t0, device: .ios))
                f.messaging.assistantActivity = AssistantActivity(phase: .working, sessionKey: AuditMessaging.claude.sessionKey, agentName: "Claude Code",
                                                                   detail: "Drafting release notes from 37 merged pull requests", progress: 0.35, since: t0)
                try await Snap.render("panel-typing-working", look: look, settle: 0.6) { f.conversation() }
            }
            // Delivery outcomes on user bubbles, and a draft in the composer.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                f.messaging.sessions = [AuditMessaging.claude]
                f.store.add(Card(id: "c_a", kind: .message, body: "Anything else before I log off?", createdAt: t0, updatedAt: t0))
                await f.model.send("Remind me to call the venue tomorrow")
                f.messaging.assistantActivity = AssistantActivity(phase: .sent, sessionKey: AuditMessaging.claude.sessionKey, agentName: "Claude Code", detail: nil, progress: nil, since: t0)
                f.model.draft = "Also: book the 9:30 train and send Sam the slides.\nAnd remind me about the dentist on Friday morning, please."
                try await Snap.render("panel-sent-draft", look: look, settle: 0.6) { f.conversation() }
            }
            guard look.font == .pixel, !look.isHighContrast else { continue }
            // Failed + queued outcomes (pixel only).
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                let failing = FailingMessaging()
                let model = ConversationModel(cards: f.store, messaging: failing)
                f.store.add(Card(id: "c_a", kind: .message, body: "I'll be here.", createdAt: t0, updatedAt: t0))
                failing.next = .queued(reason: "Waiting for your assistant to connect.")
                await model.send("Queued message")
                failing.next = .failed(reason: "Zeus isn’t connected to your assistant, so this message wasn’t saved. Open Settings → Assistant and try again.")
                await model.send("This one failed")
                try await Snap.render("panel-delivery-outcomes", look: look, settle: 0.6) {
                    ConversationView(settings: f.settings, store: f.store, model: model, messaging: failing, status: f.status, panel: f.panel,
                                     activity: f.activity, openSettings: {}, copySetup: {}, resize: { _ in })
                }
            }
            // "↓ New message" pill: open scrolled to the first card, then a message arrives.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                longThread(f)
                f.panel.scrollTargetCardID = "c_m1"
                let host = try await Snap.render("panel-scrolled-up", look: look, settle: 0.6) { f.conversation() }
                _ = host
                f.store.add(Card(id: "c_new", kind: .message, body: "One more thing: the venue confirmed.", sessionKey: AuditMessaging.claude.sessionKey))
                try await Snap.render("panel-new-pill", look: look, settle: 0.8) { f.conversation() }
            }
        }
        try Snap.dump("render-log", Snap.log.joined(separator: "\n"))
    }

    @Test func peekVariants() async throws {
        let cards: [(String, Card, Int, String?, String?)] = [
            ("message", Card(kind: .message, title: "Build finished", body: "All 412 tests passed. Ready when you are."), 0, nil, nil),
            ("untitled", Card(kind: .message, body: "Quick heads-up: your 3 PM moved to 4."), 0, nil, nil),
            ("long-more", Card(kind: .message, title: "Summary of today's inbox", body: DemoCardKind.longMessageBody), 2, nil, nil),
            ("question", Card(kind: .question, title: "Ship it?", body: "Version 0.1.2 is built and notarized. Publish the release now?",
                              options: [CardOption(id: "y", label: "Publish", style: .primary), CardOption(id: "n", label: "Not yet")]), 0, nil, nil),
            ("question-many", Card(kind: .question, title: "Pick a venue", body: "Which venue should I book for the offsite?",
                                   options: [CardOption(id: "a", label: "Harbor Loft"), CardOption(id: "b", label: "The Greenhouse"), CardOption(id: "c", label: "Studio 9"), CardOption(id: "d", label: "Somewhere else")]), 0, nil, nil),
            ("question-text", Card(kind: .question, title: "What should I focus on?", body: "Tell me about your next task.",
                                   options: [CardOption(id: "s", label: "Skip")], input: InputSpec(placeholder: "Reply")), 0, nil, nil),
            ("high", Card(kind: .message, title: "Production is down", body: "The API is returning 502s since 14:02. I paged the on-call engineer.", priority: .high), 3, nil, nil),
            ("attachments", Card(kind: .content, title: "Your deck", body: "Here's the updated Q3 deck.",
                                 attachments: [Attachment(kind: .file, label: "Q3.key", target: "/tmp/Q3.key"), Attachment(kind: .url, label: "Notes", target: "https://example.com")]), 0, nil, nil),
            ("error", Card(kind: .question, title: "Ship it?", body: "Publish now?", options: [CardOption(id: "y", label: "Publish", style: .primary), CardOption(id: "n", label: "Not yet")]),
             0, "Couldn't send your answer. Zeus will retry when Claude Code reconnects.", nil),
            ("answered", Card(kind: .question, title: "Ship it?", body: "Publish now?", options: [CardOption(id: "y", label: "Publish", style: .primary), CardOption(id: "n", label: "Not yet")]),
             0, nil, "y"),
        ]
        for look in Snap.Look.all {
            for (name, card, more, error, answered) in cards {
                let layout = PeekLayout.measure(card: card, font: look.font, moreCount: more, error: error, answeredOptionID: answered,
                                                available: CGSize(width: 1400, height: 800))
                try await Snap.render("peek-\(name)", look: look) {
                    PeekContent(card: card, layout: layout, moreCount: more, error: error, answeredOptionID: answered,
                                tail: ZeusDialogTail(edge: .bottom, offset: 60), reveal: .full)
                        .environment(\.zeusFontChoice, look.font).environment(\.zeusAnimationsActive, false)
                }
            }
            guard look.font == .pixel else { continue }
            for edge in [ZeusDialogTail.Edge.top, .leading, .trailing] {
                let card = cards[0].1
                let layout = PeekLayout.measure(card: card, font: look.font, moreCount: 0, error: cards[8].3, answeredOptionID: nil, available: CGSize(width: 1400, height: 800))
                try await Snap.render("peek-tail-\(edge)", look: look) {
                    PeekContent(card: card, layout: layout, moreCount: 0, error: cards[8].3, answeredOptionID: nil,
                                tail: ZeusDialogTail(edge: edge, offset: 40), reveal: .full)
                        .environment(\.zeusFontChoice, look.font).environment(\.zeusAnimationsActive, false)
                }
            }
        }
    }

    @Test func avatarBadgeAndWarning() async throws {
        for look in Snap.Look.basic + [Snap.Look(appearance: .accessibilityHighContrastAqua, font: .pixel)] {
            for size in [AvatarSize.medium, .large] {
                for id in ["zeus", "ghost", "robot"] {
                    let f = Fixture(font: look.font); defer { f.cleanup() }
                    f.settings.avatarSize = size
                    f.settings.currentCharacterID = id
                    for n in 0..<(id == "robot" ? 12 : 3) { f.store.add(Card(kind: .message, body: "Unread \(n)")) }
                    f.messaging.deliveryIssue = DeliveryIssue(title: "Couldn't reach your assistant", detail: "2 replies couldn't reach Claude Code (~/Website).", pendingCount: 2, since: t0)
                    let layout = AvatarArtLayout()
                    guard let character = f.settings.currentCharacter else { continue }
                    layout.rect = AvatarArtRect(canvas: character.canvasSize, pixels: SpriteLayout.artBounds(character: character), scale: f.settings.pixelScale)
                    try await Snap.render("avatar-\(id)-\(size.rawValue)", look: look, padding: 24) {
                        SpriteAvatarView(settings: f.settings, status: f.status, messaging: f.messaging, artLayout: layout, activity: f.activity)
                    }
                }
            }
            let f = Fixture(font: look.font); defer { f.cleanup() }
            f.messaging.sessions = [AuditMessaging.claude]
            f.messaging.deliveryIssue = DeliveryIssue(title: "Couldn't reach your assistant", detail: "2 replies couldn't reach Claude Code (~/Projects/Website). It disconnected 6 min ago.", pendingCount: 2, since: t0)
            try await Snap.render("warning-popover", look: look) {
                DeliveryWarningView(messaging: f.messaging, settings: f.settings, managed: ManagedAssistantModel(settings: f.settings, controller: { nil }), close: {}, openSettings: {})
            }
        }
    }

    /// M3 mockups (docs/design/MANAGED.md): Settings → Assistant, the status panel states, the blocked card.
    @Test func managedSessionMockups() async throws {
        for look in Snap.Look.all {
            for scene in ZeusManagedSessionGallery.Scene.allCases {
                try await Snap.render("managed-\(scene.rawValue)", look: look, padding: 0) {
                    ZeusManagedSessionGallery(scene).environment(\.zeusFontChoice, look.font).environment(\.zeusAnimationsActive, false)
                }
            }
        }
    }

    /// M4-QA: the built Settings → Assistant in every ManagedSessionStatus, first run, the managed empty thread,
    /// and the menu model per state (docs/design/MANAGED.md).
    @Test func managedSessionQA() async throws {
        let states: [(String, ManagedSessionStatus)] = [
            ("off", .off), ("starting", .starting), ("running-idle", .running(.idle)), ("running-working", .running(.working)),
            ("running-unknown", .running(.unknown)), ("blocked", .blocked(reason: "Do you want to proceed?")), ("stopped", .stopped),
            ("restarting", .restarting(at: Date().addingTimeInterval(10))), ("failed", .failed(reason: "Claude Code quit 5 times in 10 minutes.")),
        ]
        let looks = [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
            .map { Snap.Look(appearance: $0, font: .system) }
        func settingsView(_ status: ManagedSessionStatus, folder: String?, missingTmux: Bool = false) -> (some View, Fixture) {
            let f = Fixture(font: .system)
            let controller = AuditManagedController()
            controller.managedStatus = status; controller.missingTmux = missingTmux
            let model = ManagedAssistantModel(settings: f.settings, controller: { controller })
            model.refreshAvailability()
            if let folder { model.chooseFolder(folder) }
            let hub = AgentMessagingHub()
            let view = AssistantSettingsView(settings: f.settings, managed: model, messaging: hub, testMessage: ComposeModel(cards: f.store, messaging: hub))
                .frame(width: 524).padding(24).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.zeusFontChoice, .system)
            return (view, f)
        }
        for look in looks {
            for (name, status) in states {
                let (view, f) = settingsView(status, folder: "/Users/alex/Assistant"); defer { f.cleanup() }
                try await Snap.render("m4-settings-\(name)", look: look, padding: 0, settle: 0.5) { view }
            }
            do {
                let (view, f) = settingsView(.off, folder: nil); defer { f.cleanup() }
                try await Snap.render("m4-first-run-settings", look: look, padding: 0, settle: 0.5) { view }
            }
            do {
                let (view, f) = settingsView(.off, folder: "/Users/alex/Assistant", missingTmux: true); defer { f.cleanup() }
                try await Snap.render("m4-settings-missing-tmux", look: look, padding: 0, settle: 0.5) { view }
            }
            do {
                let f = Fixture(font: .pixel); defer { f.cleanup() }
                f.settings.managedSession = AppSettings.newManagedSession(enabled: true)
                try await Snap.render("m4-first-run-thread", look: Snap.Look(appearance: look.appearance, font: .pixel)) { f.conversation() }
            }
        }
        // The menu bar per state: status line, items (enabled?) and icon.
        var lines: [String] = []
        for (name, status) in states {
            let f = Fixture(font: .system); defer { f.cleanup() }
            let controller = AuditManagedController(); controller.managedStatus = status
            let model = ManagedAssistantModel(settings: f.settings, controller: { controller })
            model.refreshAvailability(); model.chooseFolder("/Users/alex/Assistant")
            let items = model.menuActions.map { a in a.menuTitle + ((a == .start || a == .restart) && !model.canStart ? " (disabled)" : "") }
            lines.append("\(name): status=\"\(model.menuStatus(usual: "Ready to talk", unread: 0))\" items=\(items) icon=\(model.isMenuAlert ? "alert" : "normal")")
        }
        try Snap.dump("m4-menu-states", lines.joined(separator: "\n"))
    }

    @Test func settingsPanes() async throws {
        for look in Snap.Look.basic + [Snap.Look(appearance: .accessibilityHighContrastDarkAqua, font: .system)] {
            for tab in SettingsTab.allCases {
                for connected in [false, true] where tab == .agent || !connected {
                    let f = Fixture(font: look.font); defer { f.cleanup() }
                    let hub = AgentMessagingHub()
                    hub.previewEnabled = connected
                    let nav = SettingsNavigation(); nav.tab = tab
                    let view = SettingsView(settings: f.settings, managed: ManagedAssistantModel(settings: f.settings, controller: { nil }), cards: f.store, status: f.status, messaging: hub, preview: hub,
                                            testMessage: ComposeModel(cards: f.store, messaging: hub), injectDemo: { _ in }, resetPosition: {},
                                            navigation: nav, login: LoginItemModel(), hotKey: GlobalHotKey(), activity: f.activity,
                                            learn: LearnFromMe(settings: LearnSettings(defaults: f.defaults), root: f.root.appendingPathComponent("Activity"),
                                                               source: { AuditActivitySource() }))
                    try await Snap.render("settings-\(tab.rawValue.lowercased())\(connected ? "-connected" : "")", look: look, padding: 0, settle: 0.6) {
                        view.background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
        }
    }

    /// N2: Settings › General with Sounds on and the Zeus chime chosen (set directly, so nothing previews or plays).
    @Test func settingsGeneralSounds() async throws {
        for look in Snap.Look.basic {
            let f = Fixture(font: look.font); defer { f.cleanup() }
            f.settings.popupSoundEnabled = true
            f.settings.popupSound = .chime
            // The General pane's own content at full height (the Settings window scrolls it in 572 × 572), with the
            // styles SettingsView applies to every pane.
            let view = GeneralSettingsView(settings: f.settings, login: LoginItemModel(), hotKey: GlobalHotKey(), cards: f.store, preview: { _ in })
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                .toggleStyle(ZeusCheckboxStyle())
                .textFieldStyle(ZeusTextFieldStyle())
                .settingsBody()
                .frame(width: 524, alignment: .leading).padding(24)
                .environment(\.zeusFontChoice, .system)
                .background(Color(nsColor: .windowBackgroundColor))
            try await Snap.render("settings-general-sounds", look: look, padding: 0, settle: 0.6) { view }
        }
    }

    /// C1: Settings › Character at full height with the import buttons and one broken file listed in plain words.
    @Test func settingsCharacterImport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-c1-render-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{\n  \"id\": \"blob\"\n  \"name\": \"Blob\"\n}".utf8).write(to: folder.appendingPathComponent("Blob.json"))
        for look in Snap.Look.basic {
            let suite = "zeus-c1-render-\(UUID())"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults, userDirectory: folder)
            let view = CharacterSettingsView(settings: settings, resetPosition: {})
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                .toggleStyle(ZeusCheckboxStyle())
                .settingsBody()
                .frame(width: 524, alignment: .leading).padding(24)
                .environment(\.zeusFontChoice, .system)
                .environment(\.zeusAnimationsActive, false)
                .background(Color(nsColor: .windowBackgroundColor))
            try await Snap.render("settings-character-import", look: look, padding: 0, settle: 0.6) { view }
        }
    }

    /// T1: Settings › Appearance at full height, and the conversation panel in every bundled theme, light and dark.
    @Test func themes() async throws {
        for look in Snap.Look.basic {
            let f = Fixture(font: .system); defer { f.cleanup() }
            let view = AppearanceSettingsView(settings: f.settings)
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                .toggleStyle(ZeusCheckboxStyle())
                .settingsBody()
                .frame(width: 524, alignment: .leading).padding(24)
                .environment(\.zeusFontChoice, .system)
                .background(Color(nsColor: .windowBackgroundColor))
            try await Snap.render("settings-appearance", look: look, padding: 0, settle: 0.6) { view }
            for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
                let f = Fixture(font: .pixel); defer { f.cleanup() }
                f.settings.setTheme(id: theme.id)
                longThread(f)
                f.messaging.assistantActivity = AssistantActivity(phase: .working, sessionKey: AuditMessaging.claude.sessionKey, agentName: "Claude Code",
                                                                   detail: "Drafting release notes", progress: 0.35, since: t0)
                try await Snap.render("theme-\(theme.id)", look: look, settle: 0.6) { f.conversation() }
            }
        }
    }

    /// D19: the first-run welcome card in every bundled theme, light and dark.
    @Test func welcomeThemes() async throws {
        for look in Snap.Look.basic {
            for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
                let f = Fixture(font: .pixel); defer { f.cleanup() }
                f.settings.setTheme(id: theme.id)
                f.store.add(WelcomeCard.make(now: t0))
                try await Snap.render("welcome-\(theme.id)", look: look, settle: 0.6) { f.conversation() }
            }
        }
    }

    /// D18: the 0.1.8 text styles in every bundled theme, light and dark: links in both bubbles, a skipped question,
    /// the quiet Undo and summary lines, and the strip waiting on an open question.
    @Test func contrastSurfaces() async throws {
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        for look in Snap.Look.basic {
            for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
                let f = Fixture(font: .pixel); defer { f.cleanup() }
                f.settings.setTheme(id: theme.id)
                let s = AuditMessaging.claude.sessionKey
                f.store.add(Card(id: "u_1", kind: .userMessage, body: "Use the notes at https://example.com/q3 please", createdAt: at(0), updatedAt: at(0)))
                f.store.add(Card(id: "c_1", kind: .message, body: "Done. The **draft** is at https://example.com/draft and the old one stays put.",
                                 sessionKey: s, createdAt: at(1), updatedAt: at(1)))
                f.store.add(Card(id: "c_2", kind: .question, title: "Venue", body: "Book the usual room?",
                                 options: [CardOption(id: "y", label: "Yes", style: .primary)], sessionKey: s, createdAt: at(2), updatedAt: at(2),
                                 status: .answered, response: CardResponse(respondedAt: at(3), device: .mac, skipped: true)))
                f.store.recordNotice(ThreadNotice(kind: .appChange, createdAt: at(4), summary: "Switched to Wisp", actionTitle: "Undo"), action: {}, doneTitle: "Undone")
                f.store.recordNotice(ThreadNotice(kind: .learning, createdAt: at(5), summary: "Sent your daily summary", actionTitle: "View", detail: "Summary"))
                f.store.add(Card(id: "c_3", kind: .question, title: "Slides", body: "Update last deck, or start fresh?",
                                 options: [CardOption(id: "u", label: "Update", style: .primary), CardOption(id: "f", label: "Start fresh")],
                                 sessionKey: s, createdAt: at(6), updatedAt: at(6)))
                f.store.markAllSeen()
                try await Snap.render("contrast-\(theme.id)", look: look, settle: 0.6) { f.conversation() }
            }
        }
    }

    /// TB1: the status strip in every state, inside a panel, for every bundled theme, light and dark.
    @Test func statusStrip() async throws {
        let managed = ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: true)
        let own = ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: false)
        let states: [ZeusStatusStripModel] = [
            .waiting(questions: 1, buttons: managed), .waiting(questions: 2, buttons: managed), .unread(3, buttons: own),
            .blocked(mirrored: false, buttons: managed), .blocked(mirrored: true, buttons: managed),
            .activity("Claude is working on tests", buttons: managed), .notDelivered(buttons: own), .quiet(until: "8:00", buttons: own),
            .idle(buttons: ZeusStatusStripModel.buttons(hasTerminal: false, isManaged: false, canClear: false)),
        ]
        for look in Snap.Look.basic {
            for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
                try await Snap.render("status-strip-\(theme.id)", look: look, settle: 0.4) {
                    VStack(alignment: .leading, spacing: ZeusTheme.Spacing.m) {
                        ForEach(Array(states.enumerated()), id: \.offset) { _, model in
                            ZeusStatusStrip(model, onJump: {}, onSkip: {})
                        }
                    }
                    .frame(width: ZeusTheme.Conversation.panelWidth - 32)
                    .zeusDialog(tail: nil)
                    .environment(\.zeusTheme, theme)
                    .environment(\.zeusFontChoice, .pixel)
                }
            }
        }
    }

    /// L1: Settings › Privacy at full height with "Learn from me" on and a morning's events, the one-time sheet, and the
    /// thread's quiet "Sent your daily summary · View" line. A fake source and a temporary Activity folder only.
    @Test func privacy() async throws {
        let morning = Calendar.current.startOfDay(for: t0).addingTimeInterval(8 * 3600 + 42 * 60)
        for look in Snap.Look.basic {
            let f = Fixture(font: .system); defer { f.cleanup() }
            let learn = LearnFromMe(settings: LearnSettings(defaults: f.defaults), root: f.root.appendingPathComponent("Activity"),
                                    clock: { morning.addingTimeInterval(3 * 3600) }, source: { AuditActivitySource() })
            learn.settings.introShown = true
            learn.setEnabled(true)
            let events: [(Double, ActivityEvent.Kind, String?)] = [(0, .unlock, nil), (2, .activate, "Things"), (14, .activate, "Xcode"),
                (108, .private, nil), (113, .activate, "Xcode"), (143, .idle, nil), (171, .active, nil), (171, .activate, "Safari")]
            for (minutes, kind, name) in events {
                learn.record(ActivityEvent(t: morning.addingTimeInterval(minutes * 60), kind: kind, name: name, seconds: kind == .private ? 300 : nil))
            }
            let view = PrivacySettingsView(learn: learn)
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                .toggleStyle(ZeusCheckboxStyle())
                .settingsBody()
                .frame(width: 524, alignment: .leading).padding(24)
                .environment(\.zeusFontChoice, .system)
                .background(Color(nsColor: .windowBackgroundColor))
            try await Snap.render("settings-privacy-full", look: look, padding: 0, settle: 0.6) { view }
            try await Snap.render("settings-privacy-sheet", look: look, padding: 0, settle: 0.6) {
                LearnIntroSheet(turnOn: {}, notNow: {}).background(Color(nsColor: .windowBackgroundColor))
            }
            longThread(f)
            f.store.recordNotice(ThreadNotice(kind: .learning, createdAt: t0.addingTimeInterval(3600), summary: "Sent your daily summary",
                                              actionTitle: "View", detail: "Zeus's summary of Monday, October 12 (app usage and timing only):"))
            try await Snap.render("thread-notice", look: look, settle: 0.6) { f.conversation() }
        }
    }

    @Test func menusAndAccessibility() async throws {
        let f = Fixture(font: .pixel); defer { f.cleanup() }
        let shell = ShellController(defaults: f.defaults, cards: f.store, settings: f.settings)
        func describe(_ menu: NSMenu, depth: Int = 0) -> [String] {
            menu.items.flatMap { item -> [String] in
                let pad = String(repeating: "  ", count: depth)
                if item.isSeparatorItem { return [pad + "———"] }
                var key = ""
                if !item.keyEquivalent.isEmpty {
                    let m = item.keyEquivalentModifierMask
                    key = "  [" + (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased() + "]"
                }
                return [pad + item.title + (item.state == .on ? "  ✓" : "") + key] + (item.submenu.map { describe($0, depth: depth + 1) } ?? [])
            }
        }
        try Snap.dump("context-menu", describe(shell.makeContextMenu()).joined(separator: "\n"))
        // MB1: the menu bar icon's menu is the same model rendered by SwiftUI; dump it the same way to compare.
        let menuBar = NSHostingMenu(rootView: ZeusMenuContent(model: shell.menuModel) { _ in })
        menuBar.update()
        try Snap.dump("menu-bar-menu", describe(menuBar).joined(separator: "\n"))
        // Connect your own, with a question waiting: the strip's sentence leads, and choosing it jumps there.
        f.settings.managedSession?.enabled = false
        f.store.add(Card(id: "c_menuq", kind: .question, title: "Venue", body: "Book the usual room?", options: [CardOption(id: "y", label: "Yes")]))
        f.store.markAllSeen()
        try await Task.sleep(for: .seconds(3)) // past the new card's 2.5-s "talking" moment
        try Snap.dump("context-menu-question", describe(shell.makeContextMenu()).joined(separator: "\n"))
        f.store.clearConversation()
        f.settings.managedSession?.enabled = true

        // MB1 / PM note: the Settings tab bar must name each tab and mark the selected one.
        let tabs = try await Snap.render("ax-settings-tabs", look: .init(appearance: .aqua, font: .pixel), settle: 0.4) {
            SettingsTabBar(navigation: SettingsNavigation()).frame(width: 640).environment(\.accessibilityEnabled, true)
        }
        var tabLines: [String] = []
        Snap.axTree(tabs, into: &tabLines)
        try Snap.dump("ax-settings-tabs", tabLines.joined(separator: "\n"))

        longThread(f)
        let host = try await Snap.render("ax-thread", look: .init(appearance: .aqua, font: .pixel), settle: 0.6) { f.conversation() }
        var lines: [String] = []
        Snap.axTree(host, into: &lines)
        try Snap.dump("ax-conversation", lines.joined(separator: "\n"))

        let card = Card(kind: .question, title: "Ship it?", body: "Publish now?", options: [CardOption(id: "y", label: "Publish", style: .primary), CardOption(id: "n", label: "Not yet")])
        let layout = PeekLayout.measure(card: card, font: .pixel, moreCount: 2, error: nil, answeredOptionID: nil, available: CGSize(width: 1400, height: 800))
        let peek = try await Snap.render("ax-peek", look: .init(appearance: .aqua, font: .pixel)) {
            PeekContent(card: card, layout: layout, moreCount: 2, error: nil, answeredOptionID: nil, tail: ZeusDialogTail(edge: .bottom, offset: 60), reveal: .full)
        }
        lines = []; Snap.axTree(peek, into: &lines)
        try Snap.dump("ax-peek", lines.joined(separator: "\n"))
    }
}

extension DesignerAuditRenders {
    /// Composer selection after the panel focuses it, the pinned viewport after settling, and agent-style markdown.
    @Test func extraScenarios() async throws {
        var notes: [String] = []
        // 1. A saved draft when the panel opens: is it all selected?
        do {
            let f = Fixture(font: .pixel); defer { f.cleanup() }
            f.messaging.sessions = [AuditMessaging.claude]
            f.model.draft = "Half-written thought I want to keep"
            var editor: NSTextView?
            let host = try await Snap.render("composer-draft-focus", look: .init(appearance: .aqua, font: .pixel), settle: 0.8) { f.conversation() }
            editor = host.window?.firstResponder as? NSTextView
            if let editor {
                notes.append("composer: firstResponder=NSTextView string.count=\(editor.string.count) selectedRange=\(NSStringFromRange(editor.selectedRange()))")
            } else {
                notes.append("composer: firstResponder=\(String(describing: host.window?.firstResponder))")
            }
        }
        // 2. Long thread: where does the viewport settle relative to the newest message?
        for settle in [0.6, 2.5] {
            let f = Fixture(font: .pixel); defer { f.cleanup() }
            longThread(f)
            try await Snap.render("thread-settle-\(settle)", look: .init(appearance: .aqua, font: .pixel), settle: settle) { f.conversation() }
            #if DEBUG
            let v = f.panel.viewportForDiagnostics
            notes.append("thread settle \(settle)s: offset=\(v.offset) content=\(v.contentHeight) height=\(v.height) maxOffset=\(max(0, v.contentHeight - v.height)) newestTop=\(String(describing: f.panel.newestMessageTopForDiagnostics)) atBottom=\(f.panel.atBottom)")
            #endif
        }
        // 3. What agents actually send: block markdown, code, a long path, CJK and emoji.
        let markdown = """
        ## Summary
        I fixed the login bug and opened a PR.

        - Updated `AuthService.swift`
        - Added 3 tests
          - one for expiry
        1. Review the diff
        2. Merge when CI is green

        ```swift
        let token = try await auth.refresh()
        ```

        > Note: staging needs a redeploy.

        See https://github.com/example/very-long-repository-name/pull/12345/files#diff-abcdef0123456789 or /Users/alex/Projects/Website/Sources/Authentication/AuthService.swift
        日本語のテキストも表示できます。 Emoji: ✅ 🎉 ⚠️ *italic* ~~struck~~
        """
        for look in Snap.Look.basic + [Snap.Look(appearance: .aqua, font: .system)] {
            let f = Fixture(font: look.font); defer { f.cleanup() }
            f.messaging.sessions = [AuditMessaging.claude]
            f.store.add(Card(id: "c_md", kind: .message, title: "Pull request #12345 is ready for review — login fix and refactor of the auth service", body: markdown, createdAt: t0, updatedAt: t0))
            try await Snap.render("panel-markdown", look: look, settle: 0.8) { f.conversation() }
            let card = Card(kind: .message, title: "PR ready", body: markdown)
            let layout = PeekLayout.measure(card: card, font: look.font, moreCount: 0, error: nil, answeredOptionID: nil, available: CGSize(width: 1400, height: 800))
            try await Snap.render("peek-markdown", look: look) {
                PeekContent(card: card, layout: layout, moreCount: 0, error: nil, answeredOptionID: nil, tail: ZeusDialogTail(edge: .bottom, offset: 60), reveal: .full)
                    .environment(\.zeusFontChoice, look.font).environment(\.zeusAnimationsActive, false)
            }
        }
        try Snap.dump("extra-notes", notes.joined(separator: "\n"))
    }
}

@MainActor private final class FailingMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var next: MessageSendResult = .delivered
    func sendUserMessage(_ text: String) async -> MessageSendResult { next }
}

// MARK: - README showcase (task R)
// `render.sh readme` renders the README art into build/readme-renders/: stills as PNG, animations as numbered PNG
// frames (12 fps) that readme-assets.py turns into GIFs in docs/readme/. Everything comes from the real views and
// the sprite renderer. Fixture data only: generic names and folders.

@MainActor @Observable private final class ReadmeClock { var time: Double = 0 }

private struct ReadmeClocked<Content: View>: View {
    let clock: ReadmeClock
    let content: (Double) -> Content
    var body: some View { content(clock.time) }
}

/// One sprite frame, nearest-neighbour at a whole-number scale.
private struct ReadmeSprite: View {
    let character: SpriteCharacter
    let state: AvatarState
    let time: Double
    let scale: CGFloat
    var body: some View {
        let image = SpriteRenderer.render(character, state: state, time: max(0, time))
        Image(decorative: image, scale: 1).resizable().interpolation(.none)
            .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
}

/// A rounded pixel panel the art sits on. Outside it is the GIF key color (made transparent by readme-assets.py).
private struct ReadmeStage<Content: View>: View {
    var desktop = false
    /// GIF frames: fill outside the panel with the key color. Stills stay transparent.
    var keyed = true
    let size: CGSize
    @ViewBuilder let content: Content
    @Environment(\.zeusPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = PixelRoundedRectangle(step: 2, steps: 3)
        ZStack { content }
            .frame(width: size.width, height: size.height)
            .background(desktop ? Snap.backdrop(scheme == .dark) : palette.panel)
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.outline, lineWidth: 2))
            .background(keyed ? Readme.key : .clear)
    }
}

/// A small framed label, e.g. an agent name.
private struct ReadmeChip: View {
    let text: String
    var selected = false
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        let shape = PixelRoundedRectangle(steps: 1)
        Text(text).zeusFont(.button)
            .foregroundStyle(selected ? palette.onAccent : palette.text)
            .padding(.horizontal, ZeusTheme.Spacing.s).padding(.vertical, ZeusTheme.Spacing.xs)
            .background(shape.fill(selected ? palette.accent : palette.field))
            .overlay(shape.strokeBorder(palette.outline, lineWidth: 1))
    }
}

@MainActor private enum Readme {
    static let out = Snap.repo.appendingPathComponent("build/readme-renders")
    /// Pure magenta: never used by the palette or the sprites, so it's safe as the GIF's transparent color.
    static let key = Color(red: 1, green: 0, blue: 1)
    static let characters = CharacterLibrary.load(userDirectory: nil).characters
    static func character(_ id: String) -> SpriteCharacter {
        characters.first { $0.id == id } ?? characters[0]
    }
    static let looks: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    static func window(_ view: AnyView, appearance: NSAppearance.Name, size: CGSize) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.environment(\.zeusFontChoice, .pixel)))
        let window = NSWindow(contentRect: CGRect(x: -24000, y: -24000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.orderFrontRegardless()
        return (host, window)
    }

    static func write(_ view: NSView, to url: URL) throws {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A still at its fitting size (or `size`), on a transparent background.
    static func still(_ name: String, appearance: NSAppearance.Name, size: CGSize? = nil, settle: Double = 0.6, _ view: some View) async throws {
        let (host, window) = window(AnyView(view), appearance: appearance, size: size ?? CGSize(width: 900, height: 900))
        try await Task.sleep(for: .seconds(settle))
        if size == nil { window.setContentSize(host.fittingSize) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(settle))
        if size == nil { window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .seconds(0.1)) }
        try write(host, to: out.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }

    /// Numbered frames at `fps` for `seconds`, for readme-assets.py.
    static func frames<V: View>(_ name: String, appearance: NSAppearance.Name, size: CGSize, seconds: Double, fps: Double = 12,
                                _ content: @escaping (Double) -> V) async throws {
        let clock = ReadmeClock()
        let (host, window) = window(AnyView(ReadmeClocked(clock: clock, content: content)), appearance: appearance, size: size)
        let dir = out.appendingPathComponent("frames/\(name)")
        try? FileManager.default.removeItem(at: dir)
        try await Task.sleep(for: .seconds(0.6))
        for i in 0..<Int(seconds * fps) {
            clock.time = Double(i) / fps
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            try write(host, to: dir.appendingPathComponent(String(format: "%03d.png", i)))
        }
        try "\(fps)".write(to: dir.appendingPathComponent("fps.txt"), atomically: true, encoding: .utf8)
        window.orderOut(nil)
    }

    static let session = ConnectedSession(id: UUID(), sessionKey: "claude:/Users/alex/Assistant", agent: .claude, cwd: "/Users/alex/Assistant",
                                          clientName: "Claude Code", supportsChannel: true, tmuxPane: nil, connectedAt: t0)
    static let startSlides = Card(id: "c_slides", kind: .question, body: "Your Q3 review is Thursday at 10. Want me to start the slides?",
                                  options: [CardOption(id: "s", label: "Start them", style: .primary), CardOption(id: "n", label: "Not yet")])
    static let draftReady = Card(id: "c_draft", kind: .message, body: "First draft ready.")
}

/// The hero: the wordmark, and Zeus offering to start a task before a meeting: ask, a one-click answer, work, done.
private struct ReadmeHero: View {
    let time: Double
    @Environment(\.zeusPalette) private var palette
    static let size = CGSize(width: 880, height: 320)
    static let seconds = 12.0

    var body: some View {
        let zeus = Readme.character("zeus")
        let (state, since) = phase
        ReadmeStage(size: Self.size) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: ZeusTheme.Spacing.l) {
                    Text("Zeus").font(.custom(ZeusFonts.pixelFamily, size: 66)).foregroundStyle(palette.title)
                    Text("Your agent. Your assistant.\nYour way.")
                        .font(.custom(ZeusFonts.pixelFamily, size: 16.5)).foregroundStyle(palette.text).lineSpacing(6)
                        .fixedSize()
                    HStack(spacing: ZeusTheme.Spacing.s) {
                        ReadmeChip(text: "Claude Code"); ReadmeChip(text: "Codex"); ReadmeChip(text: "OpenCode")
                    }
                }
                .padding(.leading, 36)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 0)
                // The sprite canvas has empty columns at its sides, so the tail can tuck in.
                // Every bubble hangs from the same top edge, so the tail always points at Zeus's face.
                bubble.frame(height: 158, alignment: .top).padding(.trailing, -20)
                ReadmeSprite(character: zeus, state: state, time: time - since, scale: 4)
            }
            .padding(.trailing, 16).padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// The state at `time` and when it started. Starts and ends idle with no bubble, so the loop is seamless.
    var phase: (AvatarState, Double) {
        switch time {
        case ..<1.2: (.idle, 0)
        case ..<1.8: (.alert, 1.2)
        case ..<3.8: (.talking, 1.8)
        case ..<6.0: (.idle, 3.8)
        case ..<9.0: (.working, 6.0)
        case ..<11.4: (.happy, 9.0)
        default: (.idle, 11.4)
        }
    }

    @ViewBuilder var bubble: some View {
        switch time {
        case 1.8..<6.0:
            // The question types out, waits, then "Start them" is clicked.
            let card = Readme.startSlides
            let answered: String? = time >= 5.0 ? "s" : nil
            peek(card, answered: answered, reveal: min(1, (time - 1.8) / 1.6))
        case 6.0..<9.0:
            VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
                Text("Drafting the slides").zeusFont(.button).foregroundStyle(palette.title)
                ZeusProgressRow(value: min(1, (time - 6.0) / 2.6))
            }
            .frame(width: 220)
            .zeusDialog(tail: ZeusDialogTail(edge: .trailing, offset: 34))
            .environment(\.zeusAnimationsActive, false)
        case 9.0..<11.4:
            peek(Readme.draftReady, answered: nil, reveal: min(1, (time - 9.0) / 0.6))
        default:
            EmptyView()
        }
    }

    private func peek(_ card: Card, answered: String?, reveal: Double) -> some View {
        let layout = PeekLayout.measure(card: card, font: .pixel, moreCount: 0, error: nil, answeredOptionID: answered,
                                        available: CGSize(width: 1400, height: 800))
        return PeekContent(card: card, layout: layout, moreCount: 0, error: nil, answeredOptionID: answered,
                           tail: ZeusDialogTail(edge: .trailing, offset: 34), reveal: .fraction(reveal))
            .environment(\.zeusAnimationsActive, false)
    }
}

/// The roster: eight characters stepping through the same states together.
private struct ReadmeRoster: View {
    let time: Double
    @Environment(\.zeusPalette) private var palette
    static let ids = ["zeus", "ghost", "robot", "pumpkin", "slime", "wizard", "cat", "owl"]
    static let states: [(AvatarState, Double)] = [(.idle, 2), (.thinking, 2), (.working, 2), (.alert, 1.5), (.happy, 2)]
    static let size = CGSize(width: 880, height: 230)
    static var seconds: Double { states.map(\.1).reduce(0, +) }

    var current: (AvatarState, Double) {
        var start = 0.0
        for (state, length) in Self.states {
            if time < start + length { return (state, start) }
            start += length
        }
        return (Self.states[0].0, 0)
    }

    var body: some View {
        let (state, since) = current
        ReadmeStage(size: Self.size) {
            VStack(spacing: ZeusTheme.Spacing.l) {
                HStack(spacing: ZeusTheme.Spacing.s) {
                    ForEach(Self.states, id: \.0) { s, _ in ReadmeChip(text: s.rawValue, selected: s == state) }
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Self.ids, id: \.self) { id in
                        let character = Readme.character(id)
                        VStack(spacing: ZeusTheme.Spacing.s) {
                            ReadmeSprite(character: character, state: state, time: time - since, scale: 2)
                            Text(character.name).zeusFont(.caption).foregroundStyle(palette.secondaryText)
                        }
                        .frame(width: 104)
                    }
                }
            }
        }
    }
}

/// The peek bubble on the desktop, next to Zeus.
private struct ReadmePeek: View {
    var body: some View {
        let card = Card(kind: .question, title: "Pick a venue", body: "Which venue should I book for Friday's team dinner?",
                        options: [CardOption(id: "a", label: "Harbor Loft", style: .primary), CardOption(id: "b", label: "The Greenhouse"),
                                  CardOption(id: "c", label: "Somewhere else")])
        let layout = PeekLayout.measure(card: card, font: .pixel, moreCount: 0, error: nil, answeredOptionID: nil,
                                        available: CGSize(width: 1400, height: 800))
        ReadmeStage(desktop: true, keyed: false, size: CGSize(width: 520, height: 210)) {
            HStack(alignment: .bottom, spacing: 0) {
                PeekContent(card: card, layout: layout, moreCount: 0, error: nil, answeredOptionID: nil,
                            tail: ZeusDialogTail(edge: .trailing, offset: 34), reveal: .full)
                    .environment(\.zeusAnimationsActive, false)
                    .padding(.trailing, -12)
                ReadmeSprite(character: Readme.character("zeus"), state: .talking, time: 0.2, scale: 3)
            }
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// A morning summary and its exact file reference, followed by a relevant user question.
private struct ReadmeLearningStory: View {
    let fixture: Fixture
    let clock: ReadmeClock
    static let size = CGSize(width: 780, height: 480)
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        let phase = clock.time < 3 ? 0 : clock.time < 8 ? 1 : 2
        ReadmeStage(size: Self.size) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("A little less\nexplaining.")
                        .font(.custom(ZeusFonts.pixelFamily, size: 30)).foregroundStyle(palette.title)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(["It notices.", "It remembers.", "It helps."].enumerated()), id: \.offset) { index, text in
                            Text(text).font(.custom(ZeusFonts.pixelFamily, size: 18))
                                .foregroundStyle(index == phase ? palette.title : palette.secondaryText)
                        }
                    }
                    Text(["The context you choose.", "A morning summary.\nThe files to back it up.", "Pick up where you left off."][phase])
                        .zeusFont(.body).foregroundStyle(palette.text).frame(height: 48, alignment: .topLeading)
                    ReadmeSprite(character: Readme.character("zeus"), state: phase == 2 ? .happy : .idle,
                                 time: clock.time, scale: 3)
                }.frame(width: 300, alignment: .leading)
                fixture.conversation().padding(2).frame(width: 392, height: 432, alignment: .bottom)
            }.padding(24)
        }
    }
}

extension DesignerAuditRenders {
    @Test func readme() async throws {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York") ?? .current
        defer { NSTimeZone.default = previousZone }
        try? FileManager.default.removeItem(at: Readme.out)
        for look in Readme.looks {
            try await Readme.frames("hero-\(look.name)", appearance: look.appearance, size: ReadmeHero.size, seconds: ReadmeHero.seconds) { ReadmeHero(time: $0) }
            try await Readme.frames("roster-\(look.name)", appearance: look.appearance, size: ReadmeRoster.size, seconds: ReadmeRoster.seconds) { ReadmeRoster(time: $0) }
            try await Readme.still("peek-\(look.name)", appearance: look.appearance, ReadmePeek())
            try await conversation(look)
            try await learningConversation(look)
            try await learningStory(look)
            try await settings(look)
            try await themes(look)
        }
        NSTimeZone.default = previousZone
        for look in Readme.looks { try await learning(look) }
    }

    /// "Make me a cat character" → the Undo line → the assistant's reply, in two themes side by side (R4).
    private func themes(_ look: (name: String, appearance: NSAppearance.Name)) async throws {
        var fixtures: [Fixture] = []
        defer { fixtures.forEach { $0.cleanup() } }
        let base = Date(timeIntervalSince1970: 1_791_137_100)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        for theme in ["olympus", "phosphor"] {
            let f = Fixture(font: .pixel)
            fixtures.append(f)
            f.settings.setTheme(id: theme)
            f.messaging.sessions = [Readme.session]
            f.store.add(Card(id: "u_1", kind: .userMessage, body: "Make me a cat character.", createdAt: at(0), updatedAt: at(0)))
            f.store.recordNotice(ThreadNotice(kind: .appChange, createdAt: at(1), summary: "Added Pixel Cat", actionTitle: "Undo"),
                                 action: {}, doneTitle: "Undone")
            f.store.add(Card(id: "c_1", kind: .message, body: "Here's **Pixel Cat**. Want a different coat color?",
                             sessionKey: Readme.session.sessionKey, createdAt: at(1.1), updatedAt: at(1.1)))
        }
        let pair = HStack(alignment: .top, spacing: 24) {
            ForEach(Array(fixtures.enumerated()), id: \.offset) { _, f in f.conversation().padding(2) }
        }
        try await Readme.still("themes-\(look.name)", appearance: look.appearance, settle: 0.8, pair)
    }

    /// Ask → one-click answer → finished work with Open and Reveal → the next job in progress.
    private func conversation(_ look: (name: String, appearance: NSAppearance.Name)) async throws {
        let f = Fixture(font: .pixel); defer { f.cleanup() }
        let s = Readme.session.sessionKey
        let base = Date(timeIntervalSince1970: 1_791_137_100)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        f.messaging.sessions = [Readme.session]
        f.store.add(Card(id: "u_1", kind: .userMessage, body: "Can you get the slides ready for Thursday's review?", createdAt: at(0), updatedAt: at(0)))
        f.store.add(Card(id: "c_q", kind: .question, title: "Slides", body: "Should I update last quarter's deck, or start a fresh one?",
                         options: [CardOption(id: "u", label: "Update last deck", style: .primary), CardOption(id: "f", label: "Start fresh")],
                         sessionKey: s, createdAt: at(1), updatedAt: at(1), status: .answered,
                         response: CardResponse(optionID: "u", optionLabel: "Update last deck", respondedAt: at(2), device: .mac)))
        f.store.add(Card(id: "c_c", kind: .content, title: "Slides are ready", body: "I updated the charts with this quarter's numbers and added speaker notes.",
                         attachments: [Attachment(kind: .file, label: "Q3 review.key", target: "/Users/alex/Assistant/Q3 review.key"),
                                       Attachment(kind: .folder, label: "Charts", target: "/Users/alex/Assistant/Charts")],
                         sessionKey: s, createdAt: at(6), updatedAt: at(6)))
        f.messaging.assistantActivity = AssistantActivity(phase: .working, sessionKey: s, agentName: "Claude Code",
                                                          detail: "Exporting a PDF copy for the team", progress: 0.6, since: at(7))
        try await Readme.still("conversation-\(look.name)", appearance: look.appearance, settle: 0.8, f.conversation().padding(2))
    }

    /// RD1: a short learning story in the real conversation, with synthetic journal and rule notices.
    private func learningConversation(_ look: (name: String, appearance: NSAppearance.Name)) async throws {
        let f = Fixture(font: .pixel); defer { f.cleanup() }
        let s = Readme.session.sessionKey
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        f.messaging.sessions = [Readme.session]
        f.store.recordLearningNotice(.init(id: "readme-summary", kind: .reflection, createdAt: at(0),
            summary: "Sent your daily summary", actionTitle: "View",
            detail: "Mostly Notes and Mail yesterday, with a long break at 12:30.", ruleID: nil), action: {})
        f.store.recordLearningNotice(.init(id: "readme-rule", kind: .newRule, createdAt: at(1),
            summary: "New rule: Hold routine messages after 18:00", actionTitle: "Review", detail: nil, ruleID: "readme-rule"), action: {})
        f.store.add(Card(id: "readme-user", kind: .userMessage, body: "What was I working on before lunch?", createdAt: at(2), updatedAt: at(2)))
        f.store.recordLearningNotice(.init(id: "readme-journal", kind: .reflection, createdAt: at(2.1),
            summary: "Looked at your journal: Wed 14 Oct 09:00–Wed 14 Oct 12:00", actionTitle: "View", detail: nil, ruleID: nil), action: {})
        f.store.add(Card(id: "readme-answer", kind: .message,
            body: "The Q3 planning notes. You were reviewing the launch timeline and collecting questions for the design review.",
            sessionKey: s, createdAt: at(2.2), updatedAt: at(2.2)))
        try await Readme.still("learning-\(look.name)", appearance: look.appearance, settle: 0.8, f.conversation().padding(2))
    }

    /// Real notice updates and its real View action; no production agent or capture source is involved.
    private func learningStory(_ look: (name: String, appearance: NSAppearance.Name)) async throws {
        // Ask this test process to materialize the lazy conversation's accessibility children, as the native
        // conversation tests do. Restore its previous state; this never changes the installed app or system settings.
        let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let prior = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber ?? NSNumber(value: false)
        defer { if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: prior, with: "AXEnhancedUserInterface") } }
        if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
        let f = Fixture(font: .pixel); defer { f.cleanup() }
        f.messaging.sessions = [Readme.session]
        f.settings.typewriterEnabled = false
        f.panel.width = 388
        f.panel.screenHeight = 720
        let clock = ReadmeClock()
        let root = ReadmeLearningStory(fixture: f, clock: clock).environment(\.accessibilityEnabled, true)
        let (host, window) = Readme.window(AnyView(root), appearance: look.appearance, size: ReadmeLearningStory.size)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let dir = Readme.out.appendingPathComponent("frames/learning-story-\(look.name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let detail = "Yesterday: planning notes in Notes, then a draft in Mail.\n\nFiles: Zeus/days/2026-10-14/summary.md"
        func notice(_ summary: String) {
            f.store.recordLearningNotice(.init(id: "morning", kind: .reflection, createdAt: base,
                summary: summary, actionTitle: "View", detail: detail, ruleID: nil), action: nil)
        }
        func nodes(_ value: Any, seen: inout Set<ObjectIdentifier>, depth: Int = 0) -> [NSObject] {
            guard depth < 64, seen.count < 2048, let node = value as? NSObject,
                  seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children: [Any]
            if let accessible = node as? NSAccessibilityProtocol {
                children = accessible.accessibilityChildren() ?? []
            } else {
                let selector = NSSelectorFromString("accessibilityChildren")
                children = node.responds(to: selector) ? (node.perform(selector)?.takeUnretainedValue() as? [Any] ?? []) : []
            }
            return [node] + children.flatMap { nodes($0, seen: &seen, depth: depth + 1) }
        }
        func labels() -> [(NSObject, String)] {
            var seen: Set<ObjectIdentifier> = []
            return nodes(host, seen: &seen).map { node in
                let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { name -> String? in
                    let selector = NSSelectorFromString(name)
                    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
                }
                return (node, texts.first { !$0.isEmpty } ?? "")
            }
        }
        try await Task.sleep(for: .seconds(0.6))
        let fps = 8
        for i in 0..<(14 * fps) {
            clock.time = Double(i) / Double(fps)
            if i == 12 { notice("Daily summary ready for your assistant") }
            if i == 24 { notice("Sent your daily summary") }
            if i == 32 {
                let available = labels()
                try available.map(\.1).joined(separator: "\n").write(to: Readme.out.appendingPathComponent("learning-ax.txt"), atomically: true, encoding: .utf8)
                let view = try #require(available.first { $0.1 == "View: Sent your daily summary" }?.0)
                #expect((view as AnyObject).accessibilityPerformPress?() == true)
            }
            if i == 64 {
                f.store.add(Card(id: "morning-question", kind: .userMessage, body: "Where did I leave the launch plan?",
                                 createdAt: base.addingTimeInterval(60), updatedAt: base.addingTimeInterval(60)))
            }
            if i == 76 {
                f.store.add(Card(id: "morning-answer", kind: .message,
                                 body: "The timeline was drafted. Next up: collect questions for the design review.",
                                 sessionKey: Readme.session.sessionKey, createdAt: base.addingTimeInterval(65), updatedAt: base.addingTimeInterval(65)))
            }
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            try Readme.write(host, to: dir.appendingPathComponent(String(format: "%03d.png", i)))
        }
        try "\(fps)".write(to: dir.appendingPathComponent("fps.txt"), atomically: true, encoding: .utf8)
    }

    @Test func readmeLearningStory() async throws {
        for look in Readme.looks { try await learningStory(look) }
    }

    @Test func readmeAssistantSettings() async throws {
        for look in Readme.looks { try await settings(look) }
    }

    /// Settings › Assistant with "Zeus runs it": Claude Code running in ~/Assistant.
    private func settings(_ look: (name: String, appearance: NSAppearance.Name)) async throws {
        let f = Fixture(font: .pixel); defer { f.cleanup() }
        f.settings.managedSession = AppSettings.newManagedSession(enabled: true)
        let controller = AuditManagedController()
        controller.allInstalled = true
        let model = ManagedAssistantModel(settings: f.settings, controller: { controller })
        model.refreshAvailability()
        model.chooseFolder("/Users/alex/Assistant")
        model.perform(.start)
        controller.managedStatus = .running(.idle)
        let hub = AgentMessagingHub()
        hub.previewEnabled = true
        let view = AssistantSettingsView(settings: f.settings, managed: model, messaging: hub, testMessage: ComposeModel(cards: f.store, messaging: hub))
            .frame(width: 524).padding(24)
            // Ends just after the Folder caption, before the Permissions heading.
            .frame(width: 572, height: 638, alignment: .top).clipped()
            .padding(.bottom, 20)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        try await Readme.still("settings-\(look.name)", appearance: look.appearance, size: CGSize(width: 572, height: 658), settle: 0.8, view)
    }
}

// MARK: - D20 proposal mock-up: the smallest character editor (not app code)

/// A static mock of the proposed "Edit a Copy…" editor over the real Pixel Cat: its layers, palette and one layer's
/// pixel grid read from cat.json, and the live preview drawn by the real renderer.
private struct EditorMockup: View {
    let rows: [String]
    let palette: [(String, Color)]
    let layers: [String]
    let character: SpriteCharacter
    @Environment(\.zeusPalette) private var zp

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Edit “Pixel Cat (copy)”").zeusFont(.title).foregroundStyle(zp.title)
                Spacer()
                Text("Saved to Characters as pixel-cat-copy.json").zeusFont(.caption).foregroundStyle(zp.secondaryText)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Layers").zeusFont(.button).foregroundStyle(zp.text)
                    ForEach(layers, id: \.self) { name in
                        Text(name).zeusFont(.caption).foregroundStyle(name == "head" ? zp.onAccent : zp.text)
                            .padding(.horizontal, 8).padding(.vertical, 3).frame(width: 110, alignment: .leading)
                            .background(name == "head" ? zp.accent : .clear)
                    }
                    Text("Colors").zeusFont(.button).foregroundStyle(zp.text).padding(.top, 6)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 4), count: 4), spacing: 4) {
                        ForEach(Array(palette.enumerated()), id: \.offset) { i, entry in
                            Rectangle().fill(entry.1).frame(width: 22, height: 22)
                                .overlay(Rectangle().strokeBorder(i == 1 ? zp.focusRing : zp.outline, lineWidth: i == 1 ? 2 : 1))
                        }
                    }
                    .frame(width: 110, alignment: .leading)
                }
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(["Pencil", "Erase", "Fill", "Pick"], id: \.self) { tool in
                            Button(tool) {}.buttonStyle(ZeusButtonStyle(tool == "Pencil" ? .primary : .secondary, size: .small))
                        }
                        Spacer()
                        Button("Undo") {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    }
                    Canvas { context, size in
                        let cols = rows.map(\.count).max() ?? 1
                        let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows.count))
                        let colors = Dictionary(palette.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
                        for (y, row) in rows.enumerated() {
                            for (x, ch) in row.enumerated() {
                                let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
                                if let color = colors[String(ch)] { context.fill(Path(rect), with: .color(color)) }
                                context.stroke(Path(rect), with: .color(zp.fieldBorder.opacity(0.5)), lineWidth: 0.5)
                            }
                        }
                    }
                    .frame(width: 360, height: 300)
                    .background(zp.field)
                    .overlay(Rectangle().strokeBorder(zp.fieldBorder, lineWidth: 1))
                    Text("Layer “head”, 16 × 13. Option-click picks a color.").zeusFont(.caption).foregroundStyle(zp.secondaryText)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("On your desktop now").zeusFont(.button).foregroundStyle(zp.text)
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach([(AvatarState.idle, "idle"), (.happy, "happy"), (.alert, "alert")], id: \.1) { state, name in
                            VStack(spacing: 4) {
                                ReadmeSprite(character: character, state: state, time: 0.4, scale: 3)
                                Text(name).zeusFont(.caption).foregroundStyle(zp.secondaryText)
                            }
                        }
                    }
                    Text("Frames: working").zeusFont(.button).foregroundStyle(zp.text).padding(.top, 6)
                    ForEach(["1  body · head · tailA", "2  body · head · tailB", "+ Add Frame"], id: \.self) { line in
                        Text(line).zeusFont(.caption).foregroundStyle(line.hasPrefix("+") ? zp.title : zp.text)
                    }
                    Text("Motion: bob, 1 px, 0.5 s").zeusFont(.caption).foregroundStyle(zp.secondaryText)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Open JSON") {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                Button("Revert") {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                Button("Save") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small))
            }
        }
        .padding(22)
        .zeusDialog(tail: nil)
        .environment(\.zeusFontChoice, .pixel)
    }
}

extension DesignerAuditRenders {
    /// D20: a mock-up of the proposed character editor, light and dark, for `.team/proposals/character-editor.md`.
    @Test func editorMockup() async throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Packages").path), root.pathComponents.count > 1 {
            root.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: root.appendingPathComponent("Packages/ZeusKit/Sources/ZeusSprites/Characters/cat.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let palette = try #require(json["palette"] as? [String: String]).sorted { $0.key < $1.key }
            .compactMap { key, hex in Color(themeHex: hex).map { (key, $0) } }
        let layers = try #require(json["layers"] as? [String: Any])
        let head = try #require((layers["head"] as? [String: Any])?["rows"] as? [String])
        for look in Snap.Look.basic {
            try await Snap.render("editor-mockup", look: look, settle: 0.5) {
                EditorMockup(rows: head, palette: Array(palette.prefix(16)), layers: ["body", "head", "earsUp", "eyes", "eyesBlink", "whiskers", "tailA", "tailB"].filter { layers[$0] != nil },
                             character: Readme.character("cat"))
            }
        }
    }
}

// MARK: - LM2: privacy, journal and rules mock-ups (docs/design/PRIVACY.md)

/// Settings chrome for the LM2 mock-ups: the system font and Settings' own button and checkbox styles.
private struct LM2Settings<Content: View>: View {
    var width: CGFloat = 524
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) { content() }
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle()).settingsBody()
            .frame(width: width, alignment: .leading).padding(24)
            .environment(\.zeusFontChoice, .system)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A record as stored: placeholders (‹…›) in secondary text so redactions stand out.
private struct StoredText: View {
    let text: String
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        var result = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "‹"), let close = rest[open...].firstIndex(of: "›") {
            result += AttributedString(String(rest[..<open]))
            var tag = AttributedString(String(rest[open...close])); tag.foregroundColor = palette.secondaryText
            result += tag
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return Text(result)
    }
}

private struct LM2AppList: View {
    let apps: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
            ForEach(apps, id: \.self) { app in
                HStack(spacing: ZeusTheme.Spacing.s) {
                    Image(systemName: "app.dashed").frame(width: 16, height: 16)
                    Text(app).settingsBody()
                    Spacer()
                    Button("–") {}.accessibilityLabel("Remove \(app)")
                }
            }
            Button("Add App…") {}
        }
    }
}

private struct LM2PrivacyPane: View {
    @State var coin = 1
    @State var keep = 90
    var body: some View {
        LM2Settings {
            Text("Learn from me").settingsTitle()
            Text("Private details are removed on this Mac before anything is kept.").settingsCaption()
            SettingsDivider()
            Text("Apps and timing").settingsHeading()
            Toggle("Let Zeus learn when and in what I work", isOn: .constant(true))
            Text("Zeus notes which app is in front, app launches and quits, when you lock, sleep or step away, and how many displays you use.").settingsCaption()
            SettingsDivider()
            Text("Windows and pages").settingsHeading()
            Toggle("Let Zeus keep window titles and web addresses", isOn: .constant(true))
            Text("Zeus keeps the title of the window in front, the file it shows, and the address of the web page, so your assistant knows what you were working on. Never what's inside the window.").settingsCaption()
            HStack(spacing: 0) {
                Text("Waiting for Accessibility permission. · ").settingsCaption()
                Text("Open System Settings").settingsCaption().underline()
            }
            SettingsSegments(label: "Record in", options: [(0, "Everywhere except my private list"), (1, "Only in apps I choose")], selection: $coin)
            Text(coin == 0 ? "Apps on your private list are never recorded at any level. Time in them counts only as private."
                           : "Zeus records this level only in these apps.").settingsCaption()
            LM2AppList(apps: coin == 0 ? ["Banking", "Messages"] : ["Xcode", "Chrome", "Mail"])
            SettingsSegments(label: "Keep for", options: [(7, "7 days"), (30, "30 days"), (90, "90 days")], selection: $keep)
            SettingsDivider()
            Text("What Zeus kept").settingsHeading()
            Text("Every record exactly as stored, and everything sent to your assistant.").settingsCaption()
            Button("Open What Zeus Kept…") {}
        }
    }
}

private struct LM2ConsentSheet: View {
    @Environment(\.zeusPalette) private var palette
    let keeps = ["The title of the window in front, when it changes", "The file a document window shows",
                 "The web address in Chrome and Edge", "The subject of the Mail message you're reading"]
    let never = ["What's inside a window: text, pictures, messages", "Anything while a password field is active",
                 "Private browser windows", "Apps on your private list"]
    var body: some View {
        LM2Settings(width: 460) {
            Text("Windows and pages").settingsTitle()
            Text("Zeus keeps the title of the window in front, the file it shows and the web address, so your assistant can tell what you were working on and help at the right moment.")
                .fixedSize(horizontal: false, vertical: true)
            list("Zeus keeps", keeps)
            list("Zeus never keeps", never)
            Text("An example of what's stored").settingsHeading()
            ZeusFieldChrome {
                VStack(alignment: .leading, spacing: 2) {
                    StoredText(text: "09:41  Mail    Subject: Lunch with ‹name› on Friday")
                    StoredText(text: "09:44  Chrome  Q3 planning – Docs · docs.example.com/d/‹id›")
                    StoredText(text: "09:52  Xcode   ManagedSessionController.swift — Zeus")
                }.font(.system(size: 11, design: .monospaced))
            }
            Text("Names, emails, numbers and other private details become placeholders like ‹name› before anything is stored.").settingsCaption()
            Text("Safari: Zeus keeps only that you used Safari, because it can't tell private windows apart.").settingsCaption()
            Text("Summaries of this go to your assistant, which sends them to its model provider like any message. The records themselves stay on this Mac.").settingsCaption()
            Text("Next, macOS asks you to allow Zeus under Accessibility. Zeus uses it only to read window titles.").settingsCaption()
            HStack { Spacer(); Button("Not Now") {}; Button("Continue") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small)) }
        }
    }
    func list(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).settingsHeading()
            ForEach(items, id: \.self) { Text("· " + $0).settingsBody() }
        }
    }
}

private struct LM2KeptWindow: View {
    let sent: Bool
    @Environment(\.zeusPalette) private var palette
    let rows: [(String, String, String)] = [
        ("09:52", "Xcode", "ManagedSessionController.swift — Zeus"),
        ("09:44", "Chrome", "Q3 planning – Docs · docs.example.com/d/‹id›"),
        ("09:41", "Mail", "Subject: Lunch with ‹name› on Friday"),
        ("09:30", "Private", "Private · 12 min"),
        ("09:12", "Safari", "Safari · details not kept"),
        ("09:05", "Slack", "#design-review · thread with ‹name›"),
        ("08:58", "Things", "Things — Today"),
    ]
    var body: some View {
        LM2Settings(width: 672) {
            HStack {
                Button("Kept on this Mac") {}.buttonStyle(ZeusButtonStyle(sent ? .secondary : .primary, size: .small))
                Button("Sent to your assistant") {}.buttonStyle(ZeusButtonStyle(sent ? .primary : .secondary, size: .small))
                Spacer()
            }
            if sent {
                Text("Everything Zeus sent your assistant about you. Your assistant's model provider received these like any message.").settingsCaption()
                ledger("08:00", "Morning summary", "■ Claude · Zeus", "212 words", expanded: true)
                ledger("Yesterday 18:42", "Day reflection", "■ Claude · Zeus", "388 words", expanded: false)
                ledger("Yesterday 14:05", "Note", "■ Claude · Zeus", "31 words", expanded: false)
            } else {
                HStack {
                    Button("‹") {}; Text("Today").settingsBody(); Button("›") {}.disabled(true)
                    Spacer()
                    Button("All levels ▾") {}; Button("All apps ▾") {}
                    ZeusFieldChrome { Text("Search what Zeus kept").foregroundStyle(palette.secondaryText) }.frame(width: 190)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.s) {
                            Text(row.0).settingsCaption().frame(width: 44, alignment: .leading)
                            Text(row.1).settingsBody().frame(width: 70, alignment: .leading)
                            StoredText(text: row.2).settingsBody().foregroundStyle(row.1 == "Private" || row.1 == "Safari" ? palette.secondaryText : palette.text)
                            Spacer()
                            if i == 1 { Button("Delete") {} }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 6)
                        .background(i == 1 ? palette.field : .clear)
                        if i < rows.count - 1 { SettingsDivider() }
                    }
                }
                HStack {
                    Text("Deleted. · Undo").settingsCaption()
                    Spacer()
                    Button("Delete This Day…") {}
                    Button("Export…") {}
                }
                Text("Exports what's shown, as stored.").settingsCaption()
            }
        }
    }
    func ledger(_ time: String, _ kind: String, _ session: String, _ size: String, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: ZeusTheme.Spacing.s) {
                Text(expanded ? "▾" : "▸").settingsCaption()
                Text(time).settingsCaption().frame(width: 104, alignment: .leading)
                Text(kind).settingsBody()
                Text(session).settingsCaption()
                Spacer()
                Text(size).settingsCaption()
            }
            if expanded {
                ZeusFieldChrome {
                    Text("Monday, 12 October. Mostly Xcode (4 h 10 min) on ManagedSessionController.swift, Chrome on “Q3 planning – Docs”, Mail at 09:41. Away 12:30–13:15. A private app for 12 min. You skipped one question (release notes) and pressed Undo once.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct LM2Meter: View {
    let cells: Int
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in Rectangle().fill(i < cells ? palette.focusRing : palette.fieldBorder).frame(width: 6, height: 9) }
        }.accessibilityHidden(true)
    }
}

private struct LM2RulesPane: View {
    @State var dial = 1
    let captions = ["Every new rule waits in Suggested until you turn it on.",
                    "Rules about timing and tone start at once. Rules that act for you show what they'd have done once, and wait for your OK.",
                    "Rules start at once. Rules that act for you show what they'd have done and wait for your OK, then act without asking. Undo is always there."]
    var body: some View {
        LM2Settings {
            Text("Rules").settingsTitle()
            SettingsSegments(label: "New rules", options: [(0, "Ask me first"), (1, "Balanced"), (2, "Just do it")], selection: $dial)
            Text(captions[dial]).settingsCaption()
            SettingsDivider()
            Text("Active · 2").settingsHeading()
            rule("Hold Slack messages after 18:00 on weekdays", "Weekdays from 18:00 · in Slack · held, not dropped", cells: 3, word: "Fairly sure", source: "from your assistant · 3 days ago")
            rule("Don't interrupt while tests are failing in Xcode", "When tests fail · in Xcode · until they pass", cells: 5, word: "Sure", source: "added by you")
            SettingsDivider()
            Text("Waiting for your OK · 1").settingsHeading()
            VStack(alignment: .leading, spacing: 3) {
                Text("Tell the team chat when I'm running late for stand-up").settingsBody()
                Text("Weekdays 09:55–10:05 · when you're not at your Mac").settingsCaption()
                Text("Seen once: would have sent “Running late, 10 min” to the team chat").settingsCaption()
                HStack { Button("OK") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small)); Button("Not This") {} }
            }
            SettingsDivider()
            Text("Suggested · 1").settingsHeading()
            VStack(alignment: .leading, spacing: 3) {
                Text("Have the open pull requests ready at 8:50 on Mondays").settingsBody()
                HStack(spacing: 6) { LM2Meter(cells: 2); Text("Unsure · from your assistant · today").settingsCaption() }
                HStack { Button("Turn On") {}; Button("Dismiss") {} }
            }
            SettingsDivider()
            Button("Show 3 retired") {}
            Button("Add Rule…") {}
        }
    }
    func rule(_ sentence: String, _ trigger: String, cells: Int, word: String, source: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sentence).settingsBody().lineLimit(2)
                Text(trigger).settingsCaption()
                HStack(spacing: 6) { LM2Meter(cells: cells); Text("\(word) · \(source)").settingsCaption() }
                    .accessibilityElement(children: .combine).accessibilityLabel("Confidence: \(word)")
            }
            Spacer()
            Toggle("", isOn: .constant(true)).labelsHidden().accessibilityLabel(sentence)
            Button("⋯") {}.accessibilityLabel("More for this rule")
        }
    }
}

extension DesignerAuditRenders {
    /// LM2-D: Settings › Privacy levels, the Level 2 consent sheet, What Zeus Kept, Settings › Rules and the quiet thread lines.
    @Test func privacyMockups() async throws {
        for look in Snap.Look.basic {
            try await Snap.render("lm2-privacy-pane", look: look, padding: 0, settle: 0.5) { LM2PrivacyPane() }
            try await Snap.render("lm2-privacy-pane-everywhere", look: look, padding: 0, settle: 0.5) { LM2PrivacyPane(coin: 0) }
            try await Snap.render("lm2-consent-level2", look: look, padding: 0, settle: 0.5) { LM2ConsentSheet() }
            try await Snap.render("lm2-kept", look: look, padding: 0, settle: 0.5) { LM2KeptWindow(sent: false) }
            try await Snap.render("lm2-sent", look: look, padding: 0, settle: 0.5) { LM2KeptWindow(sent: true) }
            try await Snap.render("lm2-rules", look: look, padding: 0, settle: 0.5) { LM2RulesPane() }
            let f = Fixture(font: look.font); defer { f.cleanup() }
            f.store.add(Card(id: "c_m1", kind: .message, body: "Tests passed. I'll hold the release notes until tomorrow morning.", sessionKey: AuditMessaging.claude.sessionKey, createdAt: t0, updatedAt: t0))
            f.messaging.sessions = [AuditMessaging.claude]
            let lines = ["New rule: Hold Slack messages after 18:00 · Review",
                         "I'd have sent “Running late, 10 min” to the team chat · OK next time?",
                         "Held 2 messages for your rule “No interruptions while tests fail” · Show",
                         "3 new rules · Review"]
            for (i, line) in lines.enumerated() {
                let parts = line.components(separatedBy: " · ")
                f.store.recordNotice(ThreadNotice(kind: .learning, createdAt: t0.addingTimeInterval(Double(i + 1) * 60),
                                                  summary: parts[0], actionTitle: parts.count > 1 ? parts[1] : nil), action: {})
            }
            try await Snap.render("lm2-thread-lines", look: look, settle: 0.6) { f.conversation() }
        }
    }
}

// MARK: - LM2 Phase B: Level 3 "Screen" mock-ups (docs/design/PRIVACY.md §9)

/// A drawn browser window after redaction: covered text lines (solid boxes) and a pixellated portrait.
private struct LM2MockFrame: View {
    var outlined = false
    var code = false
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, u = w / 360
            if code {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color(white: 0.12))
                    Rectangle().fill(Color(white: 0.18)).frame(height: 18 * u)
                    Rectangle().fill(Color(white: 0.15)).frame(width: 60 * u).offset(y: 18 * u)
                    ForEach(0..<9, id: \.self) { i in
                        Rectangle().fill(Color(red: 0.6, green: 0.65, blue: 0.85)).frame(width: [180, 210, 150, 230, 120, 200, 90, 160, 60][i] * u, height: 4 * u)
                            .offset(x: (72 + (i % 3 == 0 ? 0 : 12)) * u, y: (28 + CGFloat(i) * 12) * u)
                    }
                    Rectangle().fill(Color(white: 0.08)).frame(width: 300 * u, height: 70 * u).offset(x: 60 * u, y: 155 * u)
                    Rectangle().fill(Color.red.opacity(0.8)).frame(width: 200 * u, height: 4 * u).offset(x: 70 * u, y: 170 * u)
                    cover(x: 70, y: 184, w: 160, h: 8, u: u)
                }
                .frame(width: w, height: h, alignment: .topLeading).clipped()
            } else {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.97))
                Rectangle().fill(Color(white: 0.88)).frame(height: 18 * u)
                Rectangle().fill(.white).frame(width: 150 * u, height: 10 * u).offset(x: 105 * u, y: 4 * u)
                Text("Northwind Bank — Checking").font(.system(size: 11 * u, weight: .semibold)).foregroundStyle(.black).offset(x: 14 * u, y: 28 * u)
                ForEach(0..<2, id: \.self) { i in cover(x: 14, y: 48 + CGFloat(i) * 16, w: [190, 150][i], h: 10, u: u) }
                ForEach(0..<4, id: \.self) { i in
                    Rectangle().fill(Color(white: 0.75)).frame(width: [170, 150, 160, 140][i] * u, height: 4 * u).offset(x: 14 * u, y: (100 + CGFloat(i) * 14) * u)
                }
                // The pixellated portrait: 6×7 cells of skin, hair and suit tones.
                let cells: [[Double]] = [[0.2,0.25,0.3,0.3,0.25,0.2],[0.25,0.6,0.65,0.65,0.6,0.25],[0.3,0.62,0.7,0.7,0.62,0.3],
                                         [0.3,0.6,0.66,0.66,0.6,0.3],[0.85,0.9,0.92,0.92,0.9,0.85],[0.9,0.95,0.8,0.85,0.95,0.9],[0.9,0.92,0.95,0.95,0.92,0.9]]
                VStack(spacing: 0) {
                    ForEach(0..<cells.count, id: \.self) { r in
                        HStack(spacing: 0) { ForEach(0..<6, id: \.self) { c in Rectangle().fill(Color(hue: 0.07, saturation: cells[r][c] < 0.8 ? 0.35 : 0.02, brightness: cells[r][c])).frame(width: 9 * u, height: 9 * u) } }
                    }
                }
                .offset(x: 270 * u, y: 40 * u)
                .overlay(alignment: .topLeading) { if outlined { Rectangle().strokeBorder(palette.focusRing, lineWidth: 1).frame(width: 54 * u, height: 63 * u).offset(x: 270 * u, y: 40 * u) } }
            }
            .frame(width: w, height: h, alignment: .topLeading).clipped()
            }
        }
    }
    @ViewBuilder func cover(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, u: CGFloat) -> some View {
        Rectangle().fill(palette.fieldBorder).overlay(Rectangle().strokeBorder(outlined ? palette.focusRing : palette.outline, lineWidth: 1))
            .frame(width: w * u, height: h * u).offset(x: x * u, y: y * u)
    }
}

private struct LM2ScreenSection: View {
    @State var cap = 12
    @State var keep = 90
    let caption: String
    var body: some View {
        LM2Settings {
            Text("Screen").settingsHeading()
            Toggle("Let Zeus look at the window in front now and then", isOn: .constant(true))
            Text("Zeus takes a picture of the window in front at sensible moments, covers private text and blurs pictures on this Mac, and keeps a one-line description of what you were doing. Never the whole screen.").settingsCaption()
            Text(caption).settingsCaption()
            SettingsSegments(label: "Record in", options: [(0, "Everywhere except my private list"), (1, "Only in apps I choose")], selection: .constant(0))
            SettingsSegments(label: "Up to", options: [(4, "4 an hour"), (12, "12 an hour"), (30, "30 an hour")], selection: $cap)
            Text("Pictures that look the same as the last one don't count.").settingsCaption()
            SettingsSegments(label: "Keep descriptions for", options: [(30, "30 days"), (90, "90 days")], selection: $keep)
            Text("Pictures are deleted after 7 days.").settingsCaption()
        }
    }
}

private struct LM2ScreenConsent: View {
    let keeps = ["A picture of the window in front, with private text covered and pictures blurred, for 7 days",
                 "A one-line description of what you were doing, for 90 days"]
    let never = ["The rest of your screen or other windows", "Anything during a video call or while presenting",
                 "Anything while a password field is active", "Private windows and apps on your private list", "Sound"]
    var body: some View {
        LM2Settings(width: 460) {
            Text("Screen").settingsTitle()
            Text("Zeus takes a picture of the window in front at sensible moments, so your assistant knows what you were looking at. Before anything is kept, Zeus covers private text and blurs pictures and faces, here on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            list("Zeus keeps", keeps)
            list("Zeus never keeps", never)
            Text("When Zeus looks").settingsHeading()
            Text("Zeus doesn't record your screen. It takes one picture of the window in front when something has changed: after you've switched to an app or document and stayed for 10 seconds, every 5 minutes if you stay in the same place, when you come back from a break, and when you ask. It skips the picture if the window looks the same as last time. It never takes one during a video call, while your screen is mirrored for a presentation, while a password field is active, or in private windows and apps on your private list.").settingsCaption()
            Text("An example of what's kept").settingsHeading()
            ZeusFieldChrome {
                VStack(alignment: .leading, spacing: 6) {
                    LM2MockFrame().frame(width: 360, height: 225).overlay(Rectangle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                    Text("10:12  Safari  Reviewing account information.").font(.system(size: 11, design: .monospaced))
                }
            }
            Text("Grey boxes are text Zeus covered. Pictures and faces are blurred. The picture is kept for 7 days, the description for 90.").settingsCaption()
            Text("Descriptions go to your assistant in summaries, like any message. Pictures never leave this Mac unless you attach one yourself.").settingsCaption()
            Text("Next, macOS asks you to allow Zeus under Screen Recording. Zeus uses it only for these pictures.").settingsCaption()
            HStack { Spacer(); Button("Not Now") {}; Button("Continue") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small)) }
        }
    }
    func list(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).settingsHeading()
            ForEach(items, id: \.self) { Text("· " + $0).settingsBody().fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct LM2PictureRows: View {
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        LM2Settings(width: 672) {
            HStack {
                Button("‹") {}; Text("Today").settingsBody(); Button("›") {}.disabled(true)
                Spacer()
                Button("Screen ▾") {}; Button("All apps ▾") {}
            }
            row(time: "10:12", app: "Safari", text: "Reviewing account information.", caption: "Picture · 6 days left", picture: true)
            SettingsDivider()
            row(time: "09:52", app: "Xcode", text: "Debugging a session restart that failed to resume.", caption: "Picture · 6 days left", picture: true, code: true)
            SettingsDivider()
            row(time: "09:31", app: "Mail", text: "Reading a message about ‹name›'s lunch plans.", caption: "Picture not kept: it looked private", picture: false)
        }
    }
    func row(time: String, app: String, text: String, caption: String, picture: Bool, code: Bool = false) -> some View {
        HStack(alignment: .top, spacing: ZeusTheme.Spacing.s) {
            Text(time).settingsCaption().frame(width: 44, alignment: .leading)
            Group {
                if picture { LM2MockFrame(code: code) } else { ZStack { Rectangle().fill(palette.field); Text("No picture").settingsCaption() } }
            }
            .frame(width: 96, height: 60).overlay(Rectangle().strokeBorder(palette.outline, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(app).settingsBody()
                StoredText(text: text).settingsBody()
                Text(caption).settingsCaption()
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct LM2PictureDetail: View {
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        LM2Settings(width: 760) {
            Text("Picture from 10:12").settingsTitle()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    LM2MockFrame(outlined: true).frame(width: 448, height: 280).overlay(Rectangle().strokeBorder(palette.outline, lineWidth: 1))
                        .accessibilityElement().accessibilityLabel("Picture of Safari, 3 areas covered")
                    Text("▭ Covered text · ▭ Blurred picture · 2 covered · 1 blurred").settingsCaption()
                }
                VStack(alignment: .leading, spacing: 8) {
                    field("App", "Safari")
                    field("Window", "Northwind Bank — Checking · bank.example.com/‹id›")
                    field("Description", "Reviewing account information.")
                    Text("Kept until Mon 19 Oct").settingsCaption()
                }
            }
            HStack {
                Text("← → previous and next picture").settingsCaption()
                Spacer()
                Button("Delete Picture") {}; Button("Delete Both…") {}; Button("Close") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small))
            }
        }
    }
    func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(label).settingsHeading(); StoredText(text: value).settingsBody().fixedSize(horizontal: false, vertical: true) }
    }
}

private struct LM2AskChips: View {
    let allLevels: Bool
    @Environment(\.zeusPalette) private var zp
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if allLevels {
                Text("From the window in front, with private details removed. Remove anything you don't want to send.")
                    .zeusFont(.caption).foregroundStyle(zp.secondaryText).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    chip("Window · ManagedSessionController.swift")
                    chip("Selection · 42 words")
                }
                HStack(spacing: 6) {
                    chip("Page · docs.example.com")
                    chip("Picture · Xcode", picture: true)
                }
            } else {
                Text("Turn on Windows and pages or Screen in Settings › Privacy to attach what's in front.")
                    .zeusFont(.caption).foregroundStyle(zp.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ZeusFieldChrome(isFocused: true) { Text("Why is this test failing?").zeusFont(.body) }
                Button("↑") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small))
            }
        }
        .padding(18).frame(width: 400)
        .zeusDialog(tail: nil)
        .environment(\.zeusFontChoice, .pixel)
    }
    func chip(_ label: String, picture: Bool = false) -> some View {
        HStack(spacing: 5) {
            if picture { LM2MockFrame(code: true).frame(width: 32, height: 20).overlay(Rectangle().strokeBorder(zp.outline, lineWidth: 1)) }
            Text(label).zeusFont(.caption).foregroundStyle(zp.text).lineLimit(1)
            Text("×").zeusFont(.caption).foregroundStyle(zp.secondaryText).accessibilityLabel("Remove")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(PixelRoundedRectangle(steps: 1).fill(zp.field))
        .overlay(PixelRoundedRectangle(steps: 1).stroke(zp.fieldBorder, lineWidth: ZeusTheme.pixel))
    }
}

extension DesignerAuditRenders {
    /// LM2-D2: Level 3 "Screen": the Settings section, consent sheet, pictures in What Zeus Kept, the picture detail and Ask About This chips.
    @Test func screenMockups() async throws {
        for look in Snap.Look.basic {
            try await Snap.render("lm2b-screen-section", look: look, padding: 0, settle: 0.5) {
                LM2ScreenSection(caption: "macOS may show its screen-recording indicator for a moment when Zeus takes a picture, and may ask now and then whether Zeus can still see your screen.")
            }
            try await Snap.render("lm2b-screen-section-paused", look: look, padding: 0, settle: 0.5) { LM2ScreenSection(caption: "Paused: a video call is on") }
            try await Snap.render("lm2b-consent-level3", look: look, padding: 0, settle: 0.5) { LM2ScreenConsent() }
            try await Snap.render("lm2b-kept-pictures", look: look, padding: 0, settle: 0.5) { LM2PictureRows() }
            try await Snap.render("lm2b-picture-detail", look: look, padding: 0, settle: 0.5) { LM2PictureDetail() }
            try await Snap.render("lm2b-ask-chips", look: look, settle: 0.5) { LM2AskChips(allLevels: true) }
            try await Snap.render("lm2b-ask-none", look: look, settle: 0.5) { LM2AskChips(allLevels: false) }
        }
    }
}

// MARK: - LM2 Phase C: Level 4 "Typing" mock-ups (docs/design/PRIVACY.md §10)

private struct LM2TypingSection: View {
    @State var keep = 24
    var caption: String? = nil
    var aiOff = false
    var body: some View {
        LM2Settings {
            Text("Typing").settingsHeading()
            Toggle("Let Zeus keep what I type in apps I choose", isOn: .constant(!aiOff)).disabled(aiOff)
            Text("Zeus notes what you were typing about, like \u{201C}replying to a doctor about rescheduling\u{201D}, so your assistant can help with it. Only in the apps you choose, and never in password fields.").settingsCaption()
            if aiOff {
                Text("Typing needs Apple Intelligence, which removes names and numbers from what you type. Turn it on in System Settings › Apple Intelligence & Siri.").settingsCaption()
            } else {
                if let caption { Text(caption).settingsCaption() }
                HStack(spacing: ZeusTheme.Spacing.s) { Text("Record in").settingsBody(); Text("Only in apps I choose").settingsCaption() }
                LM2AppList(apps: ["Mail", "Notes", "Xcode"])
                Text("Zeus never records typing in an app you haven't added.").settingsCaption()
                SettingsSegments(label: "Keep the words", options: [(0, "Don't keep"), (24, "24 hours"), (168, "7 days")], selection: $keep)
                Text("Topics are kept for 30 days. The words, with private details removed, are kept as you choose here.").settingsCaption()
            }
        }
    }
}

private struct LM2TypingConsent: View {
    let keeps = ["What each stretch of typing was about, for 30 days",
                 "The words, with private details removed, for 24 hours (you can change this, or keep no words at all)"]
    let never = ["Anything you type into a password field", "Typing in apps you haven't chosen, or in private windows",
                 "What you paste: Zeus only notes that you pasted", "Typing made by other apps, such as a password manager filling in a form"]
    var body: some View {
        LM2Settings(width: 460) {
            Text("Typing").settingsTitle()
            Text("Zeus notes what you were typing about in the apps you choose, so your assistant knows what you're working on and can help with it. Before anything is kept, Zeus removes names, numbers, addresses and secrets, here on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            list("Zeus keeps", keeps)
            list("Zeus never keeps", never)
            Text("An example").settingsHeading()
            ZeusFieldChrome {
                VStack(alignment: .leading, spacing: 4) {
                    StoredText(text: "14:05  Mail  hi dr ‹name› can we move thursday to 3pm my ‹health› is still sore")
                    Text("       → Replying to a doctor about rescheduling an appointment")
                }.font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            }
            Text("The first line is the words as kept for 24 hours. The second is the topic kept for 30 days. Your assistant can read both while they're kept.").settingsCaption()
            Text("Topics go to your assistant in summaries, like any message. The words never leave this Mac.").settingsCaption()
            Text("Next, macOS asks you to allow Zeus under Input Monitoring. Zeus uses it only to read keys in the apps you choose.").settingsCaption()
            Text("If you'd rather keep no words, choose Don't keep after turning this on. Topics still work.").settingsCaption()
            HStack { Spacer(); Button("Not Now") {}; Button("Continue") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small)) }
        }
    }
    func list(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).settingsHeading()
            ForEach(items, id: \.self) { Text("· " + $0).settingsBody().fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct LM2TypingKept: View {
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        LM2Settings(width: 672) {
            HStack {
                Button("‹") {}; Text("Today").settingsBody(); Button("›") {}.disabled(true)
                Spacer()
                Button("Typing ▾") {}; Button("All apps ▾") {}
            }
            group("Mail · 14:00–15:00", "3 stretches", [
                ("14:05", "Replying to a doctor about rescheduling an appointment", "hi dr ‹name› can we move thursday to 3pm my ‹health› is still sore"),
                ("14:31", "Drafting a project update for a colleague", nil),
                ("14:52", "Replying to support about a login problem", "tried again after ‹pasted› still says expired"),
            ], hovered: 0)
            SettingsDivider()
            group("Xcode · 13:00–14:00", "2 stretches", [
                ("13:12", "Coding a fix for a restart race", "fix restart race guard state idle"),
                ("13:40", "Typed in Xcode", "words deleted after 24 hours"),
            ], hovered: nil)
        }
    }
    func group(_ title: String, _ count: String, _ items: [(String, String, String?)], hovered: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("▾ " + title).settingsHeading(); Spacer(); Text(count).settingsCaption() }
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.s) {
                    Text(item.0).settingsCaption().frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("→ " + item.1).settingsBody()
                        if let words = item.2, !words.hasPrefix("words ") {
                            StoredText(text: words).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondaryText)
                        } else {
                            Text(item.2 ?? "words not kept").settingsCaption()
                        }
                    }
                    Spacer()
                    if hovered == i { Button("Delete") {} }
                }
                .padding(.vertical, 3).padding(.horizontal, 4)
                .background(hovered == i ? palette.field : .clear)
            }
        }
    }
}

/// The Zeus menu's status section while a password field is active (a mock of the NSMenu, not the real menu).
private struct LM2PrivateInputMenu: View {
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Private input: Zeus isn't noting typing").foregroundStyle(.secondary)
            Text("Claude is working…").foregroundStyle(.secondary)
            Divider()
            Text("Talk to Zeus…")
            Text("Ask About This")
            Text("Hide Zeus")
        }
        .font(.system(size: 13)).padding(10).frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
    }
}

extension DesignerAuditRenders {
    /// LM2-D3: Level 4 "Typing": the Settings section and its states, the consent sheet, typing in What Zeus Kept, and the Private input menu line.
    @Test func typingMockups() async throws {
        for look in Snap.Look.basic {
            try await Snap.render("lm2c-typing-section", look: look, padding: 0, settle: 0.5) { LM2TypingSection() }
            try await Snap.render("lm2c-typing-section-paused", look: look, padding: 0, settle: 0.5) { LM2TypingSection(caption: "Paused: private input.") }
            try await Snap.render("lm2c-typing-section-revoked", look: look, padding: 0, settle: 0.5) {
                LM2TypingSection(caption: "Input Monitoring is off for Zeus, so nothing you type is noted. · Open System Settings")
            }
            try await Snap.render("lm2c-typing-section-ai-off", look: look, padding: 0, settle: 0.5) { LM2TypingSection(aiOff: true) }
            try await Snap.render("lm2c-consent-level4", look: look, padding: 0, settle: 0.5) { LM2TypingConsent() }
            try await Snap.render("lm2c-kept-typing", look: look, padding: 0, settle: 0.5) { LM2TypingKept() }
            try await Snap.render("lm2c-private-input-menu", look: look, settle: 0.5) { LM2PrivateInputMenu() }
        }
    }
}

// MARK: - LM2 Phase D: depth mock-ups (docs/design/PRIVACY.md §11)

private struct LM2RawSwitch: View {
    var body: some View {
        LM2Settings {
            Text("Screen").settingsHeading()
            SettingsSegments(label: "Keep descriptions for", options: [(30, "30 days"), (90, "90 days")], selection: .constant(90))
            Toggle("Let my assistant see the pictures when it asks", isOn: .constant(false))
            Text("Otherwise it gets only descriptions. Each time it looks, you'll see a line in the conversation.").settingsCaption()
            SettingsDivider()
            Text("Typing").settingsHeading()
            SettingsSegments(label: "Keep the words", options: [(0, "Don't keep"), (24, "24 hours"), (168, "7 days")], selection: .constant(24))
            Toggle("Let my assistant see the words when it asks", isOn: .constant(true))
            Text("Otherwise it gets only topics. Each time it looks, you'll see a line in the conversation.").settingsCaption()
        }
    }
}

private struct LM2RawSheet: View {
    var body: some View {
        LM2Settings(width: 440) {
            Text("Let your assistant see pictures?").settingsTitle()
            Text("When your assistant asks about a moment, it can get the picture Zeus kept (with private text covered and pictures blurred), not just the description. That picture goes to your assistant's model provider, like anything you send.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Every time it looks, the conversation says so, and What Zeus Kept › Sent to your assistant shows exactly what it got.").settingsCaption()
            HStack { Spacer(); Button("Cancel") {}; Button("Allow") {}.buttonStyle(ZeusButtonStyle(.primary, size: .small)) }
        }
    }
}

private struct LM2WhyPopover: View {
    @Environment(\.zeusPalette) private var palette
    let evidence = ["Mon 12 Oct · 18:20 · Slack · #design-review", "Tue 13 Oct · 18:42 · Slack · #general"]
    let outcomes: [(String, String, String)] = [
        ("✓", "Wed 15 Oct 18:05 · Held 2 messages; you read them at 19:10", "accepted"),
        ("↶", "Thu 16 Oct 18:30 · You pressed Show before 19:00", "undone"),
        ("–", "Fri 17 Oct · The prepared list wasn't opened", "ignored"),
        ("✕", "Sat 18 Oct · You pressed Skip on its question", "skipped"),
    ]
    var body: some View {
        LM2Settings(width: 470) {
            Text("Why this rule").settingsTitle()
            Text("Based on:").settingsHeading()
            ForEach(evidence, id: \.self) { Text($0).settingsCaption() }
            Text("Proposed by your assistant on Wed 14 Oct").settingsCaption()
            SettingsDivider()
            Text("What happened since").settingsHeading()
            ForEach(outcomes, id: \.1) { o in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(o.0).settingsBody().frame(width: 14)
                    Text(o.1).settingsBody()
                    Spacer()
                    Text("(\(o.2))").settingsCaption()
                }.accessibilityElement(children: .combine)
            }
            HStack(spacing: 6) { LM2Meter(cells: 3); Text("Fairly sure · was Sure on 15 Oct").settingsCaption() }
        }
    }
}

private struct LM2JournalLedger: View {
    var body: some View {
        LM2Settings(width: 672) {
            Text("Everything Zeus sent your assistant about you. Your assistant's model provider received these like any message.").settingsCaption()
            HStack(spacing: ZeusTheme.Spacing.s) {
                Text("▾").settingsCaption(); Text("14:32").settingsCaption(); Text("Journal answer").settingsBody(); Text("■ Claude · Zeus").settingsCaption()
                Spacer(); Text("3 items").settingsCaption()
            }
            ZeusFieldChrome {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tue 14 Oct 14:00–15:30 · “pull request”").font(.system(size: 12, weight: .semibold))
                    StoredText(text: "14:05 · Mail · typing · Replying to a doctor about rescheduling an appointment")
                    StoredText(text: "14:12 · Chrome · window · Q3 planning – Docs · docs.example.com/d/‹id›")
                    HStack(spacing: 6) {
                        LM2MockFrame(code: true).frame(width: 64, height: 40)
                        StoredText(text: "14:20 · Xcode · picture · Debugging a session restart that failed to resume.")
                    }
                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: ZeusTheme.Spacing.s) {
                Text("▸").settingsCaption(); Text("11:02").settingsCaption(); Text("Journal answer").settingsBody(); Text("■ Claude · Zeus").settingsCaption()
                Spacer(); Text("Asked for pictures; not allowed").settingsCaption()
            }
        }
    }
}

extension DesignerAuditRenders {
    /// LM2-D4: Raw on request, journal-answer and acting-rule lines, Why? with outcomes, and journal answers in the ledger.
    @Test func depthMockups() async throws {
        for look in Snap.Look.basic {
            try await Snap.render("lm2d-raw-switch", look: look, padding: 0, settle: 0.5) { LM2RawSwitch() }
            try await Snap.render("lm2d-raw-sheet", look: look, padding: 0, settle: 0.5) { LM2RawSheet() }
            try await Snap.render("lm2d-why-outcomes", look: look, padding: 0, settle: 0.5) { LM2WhyPopover() }
            try await Snap.render("lm2d-ledger-journal", look: look, padding: 0, settle: 0.5) { LM2JournalLedger() }
            for (name, lines) in [("lm2d-thread-journal-shadow", ["Looked at your journal: Tue 14:00–15:30 · View",
                                                                  "Looked at your journal, including 2 pictures: Tue 14:00–15:30 · View",
                                                                  "I'd have drafted a reply to the scheduling email · OK next time?",
                                                                  "I'd have moved your 15:00 meeting to 15:30 · OK next time?",
                                                                  "I'd have bought the usual coffee beans for €14 · OK next time?"]),
                                  ("lm2d-thread-acted-retired", ["Sent “Running late, 10 min” to the team chat · Not again",
                                                                 "Drafted a reply to the scheduling email · Undo",
                                                                 "Rule turned off · Review",
                                                                 "Retired a rule you kept skipping: “Prepare PR list at 8:50” · Review"])] {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                f.store.add(Card(id: "c_m1", kind: .message, body: "The PR you had open at 14:12 was #482, the restart race fix.", sessionKey: AuditMessaging.claude.sessionKey, createdAt: t0, updatedAt: t0))
                f.messaging.sessions = [AuditMessaging.claude]
                for (i, line) in lines.enumerated() {
                    let parts = line.components(separatedBy: " · ")
                    f.store.recordNotice(ThreadNotice(kind: .learning, createdAt: t0.addingTimeInterval(Double(i + 1) * 60),
                                                      summary: parts.dropLast(parts.count > 1 ? 1 : 0).joined(separator: " · "), actionTitle: parts.count > 1 ? parts.last : nil), action: {})
                }
                try await Snap.render(name, look: look, settle: 0.6) { f.conversation() }
            }
        }
    }
}

// MARK: - LM2-R: review renders of the shipped Phase A screens (real views, fakes for stores and capture)

private struct ReviewRedactor: Redactor {
    func redact(_ text: String) async -> Redacted<String> { Redacted(text) }
}

@MainActor private final class LM2ReviewFixture {
    let f: Fixture
    let learn: LearnFromMe
    let learning: LearningPresentation
    let journal = LM2JournalFake()
    let rules = LM2RulesFake()
    let nav = SettingsNavigation()

    init(theme: String, font: ZeusFontChoice) {
        f = Fixture(font: font)
        f.settings.setTheme(id: theme)
        learn = LearnFromMe(settings: LearnSettings(defaults: f.defaults), root: f.root.appendingPathComponent("Activity"), source: { AuditActivitySource() })
        learn.settings.introShown = true
        learn.setEnabled(true)
        learning = LearningPresentation(defaults: f.defaults, learn: learn)
        learning.policies.edit(2) { $0.enabled = true; $0.consented = true }
        let now = Date(), morning = Calendar.current.startOfDay(for: now).addingTimeInterval(9 * 3600)
        func item(_ id: String, _ minutes: Double, _ level: JournalLevel, _ app: String?, _ kind: JournalKind, _ description: String, _ text: String? = nil, _ details: [String: String] = [:]) -> JournalItem {
            JournalItem(id: id, time: min(now, morning.addingTimeInterval(minutes * 60)), level: level, app: app, kind: kind,
                        payload: Redacted(JournalPayload(description: description, text: text, details: details)))
        }
        journal.records = [
            item("e1", 52, .focus, "com.apple.dt.Xcode", .focus, "Xcode", "Window: ManagedSessionController.swift — Zeus\nDocument: ManagedSessionController.swift — /Projects/Zeus"),
            item("e2", 44, .focus, "com.google.Chrome", .focus, "Chrome", "Window: Q3 planning – Docs\nAddress: docs.example.com/d/‹id›"),
            item("e3", 41, .focus, "com.apple.mail", .focus, "Mail", "Window: Lunch with ‹name› on Friday"),
            item("e4", 30, .activity, nil, .activity, "Private time · 12 min"),
            item("e5", 12, .focus, "com.apple.Safari", .focus, "Safari", "Safari · details not kept"),
            item("s1", 0, .activity, nil, .sentToAssistant, "Morning summary", "Mostly Xcode (4 h 10 min) and Chrome. Away 12:30–13:15. A private app for 12 min.", ["sessionLabel": "Claude · Zeus"]),
            item("s2", -900, .activity, nil, .sentToAssistant, "Day reflection", "Monday: Xcode in the afternoon, Mail at 09:41. You skipped one question.", ["sessionLabel": "Claude · Zeus"]),
        ]
        learning.install(journal: journal, rules: rules, redactor: ReviewRedactor(), source: LM2FocusSource())
        nav.showsRules = true
    }
    func addRules() throws {
        let created = Date().addingTimeInterval(-3 * 86400)
        _ = try rules.propose([RuleProposal(sentence: "Hold routine messages after 18:00 on weekdays", trigger: .init(time: .init(startMinute: 1080, endMinute: 540, weekdays: [2, 3, 4, 5, 6])), confidence: 0.6, evidence: ["e1", "e2"]),
                               RuleProposal(sentence: "Send a short update to the team when I'm late for stand-up", trigger: .init(time: .init(startMinute: 595, endMinute: 605)), kind: .acts, confidence: 0.55, evidence: ["e3"]),
                               RuleProposal(sentence: "Have the open pull requests ready at 8:50 on Mondays", trigger: .init(time: .init(startMinute: 530, endMinute: 540, weekdays: [2])), confidence: 0.35, evidence: ["e1"]),
                               RuleProposal(sentence: "Prepare a summary of Slack threads at 17:00", confidence: 0.15)], at: created)
        try rules.setStatus(.proposed, id: rules.rules[2].id, at: created)
        try rules.setStatus(.retired, id: rules.rules[3].id, at: created)
        _ = try rules.addOwn(RuleProposal(sentence: "Don't interrupt while tests are failing in Xcode", trigger: .init(apps: ["com.apple.dt.Xcode"], state: "tests failing"), confidence: 0.75), at: created)
    }
    func settings(_ tab: SettingsTab, morningBrief: MorningBriefSettings? = nil) -> some View {
        nav.tab = tab
        let hub = AgentMessagingHub()
        return SettingsView(settings: f.settings, managed: ManagedAssistantModel(settings: f.settings, controller: { nil }), cards: f.store, status: f.status, messaging: hub, preview: hub,
                            testMessage: ComposeModel(cards: f.store, messaging: hub), injectDemo: { _ in }, resetPosition: {},
                            navigation: nav, login: LoginItemModel(), hotKey: GlobalHotKey(), activity: f.activity, learn: learn, learning: learning,
                            morningBrief: morningBrief)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    func cleanup() { learning.stop(); f.cleanup() }
}

extension DesignerAuditRenders {
    /// LM2-R: the shipped Phase A screens in every bundled theme, light and dark.
    @Test func lm2Review() async throws {
        for look in Snap.Look.basic {
            for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
                let r = LM2ReviewFixture(theme: theme.id, font: look.font); defer { r.cleanup() }
                let id = theme.id
                try await Snap.render("lm2r-\(id)-privacy-everywhere", look: look, padding: 0, settle: 0.6) { r.settings(.privacy) }
                r.learning.policies.edit(2) { $0.scope = .chosenApps; $0.apps = [.init(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"]), .init(name: "Safari", bundleIDs: ["com.apple.Safari"])] }
                try await Snap.render("lm2r-\(id)-privacy-chosen", look: look, padding: 0, settle: 0.6) { r.settings(.privacy) }
                try await Snap.render("lm2r-\(id)-consent", look: look, padding: 0, settle: 0.5) {
                    ObservationConsentSheet(enable: {}, cancel: {}).environment(\.zeusTheme, r.f.settings.currentTheme).environment(\.zeusFontChoice, .system)
                        .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).background(Color(nsColor: .windowBackgroundColor))
                }
                if let viewer = r.learning.viewer {
                    viewer.sentOnly = false
                    try await Snap.render("lm2r-\(id)-kept", look: look, padding: 0, size: CGSize(width: 720, height: 620), settle: 0.6) {
                        JournalWindowView(model: viewer, settings: r.f.settings).background(Color(nsColor: .windowBackgroundColor))
                    }
                    viewer.sentOnly = true
                    try await Snap.render("lm2r-\(id)-sent", look: look, padding: 0, size: CGSize(width: 720, height: 420), settle: 0.6) {
                        JournalWindowView(model: viewer, settings: r.f.settings).background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                try await Snap.render("lm2r-\(id)-rules-empty", look: look, padding: 0, settle: 0.6) { r.settings(.rules) }
                try r.addRules()
                try await Snap.render("lm2r-\(id)-rules", look: look, padding: 0, settle: 0.6) { r.settings(.rules) }
                r.rules.autonomy = 0
                try await Snap.render("lm2r-\(id)-rules-askfirst", look: look, padding: 0, settle: 0.6) { r.settings(.rules) }
                r.rules.autonomy = 1
                try await Snap.render("lm2r-\(id)-rules-justdoit", look: look, padding: 0, settle: 0.6) { r.settings(.rules) }
                // The thread: the runtime's own notice wording (ZeusRuntime+Learning), recorded through CardStore's adapter.
                let s = AuditMessaging.claude.sessionKey
                r.f.store.add(Card(id: "c_m1", kind: .message, body: "Tests passed. I'll hold the release notes until tomorrow morning.", sessionKey: s, createdAt: t0, updatedAt: t0))
                r.f.messaging.sessions = [AuditMessaging.claude]
                let rule = r.rules.rules[0], shadow = r.rules.rules[1]
                r.f.store.recordLearningNotice(.init(id: "rule:" + rule.id, kind: .newRule, createdAt: t0.addingTimeInterval(60), summary: "New rule: \(rule.sentence)", actionTitle: "Review", detail: rule.sentence, ruleID: rule.id), action: {})
                r.f.store.recordLearningNotice(.init(id: "rule:group", kind: .newRule, createdAt: t0.addingTimeInterval(120), summary: "3 new rules", actionTitle: "Review", detail: nil, ruleID: nil), action: {})
                r.f.store.recordLearningNotice(.init(id: "shadow:" + shadow.id, kind: .shadow, createdAt: t0.addingTimeInterval(180), summary: "I'd have: \(shadow.sentence)", actionTitle: "OK next time?", detail: shadow.sentence, ruleID: shadow.id), action: {})
                r.f.store.recordLearningNotice(.init(id: "shadow:ok", kind: .shadow, createdAt: t0.addingTimeInterval(240), summary: "OK. I will do that from now on.", actionTitle: "Undo", detail: nil, ruleID: nil), action: {})
                r.f.store.recordLearningNotice(.init(id: "shadow:retired", kind: .shadow, createdAt: t0.addingTimeInterval(300), summary: "Rule retired: Prepare a summary of Slack threads at 17:00", actionTitle: nil, detail: "Prepare a summary of Slack threads at 17:00", ruleID: nil), action: nil)
                // Dropped items waiting in the composer.
                r.f.model.attach([Attachment(kind: .file, label: "Q3 review.key", target: "/Users/alex/Documents/Q3 review.key"),
                                  Attachment(kind: .folder, label: "Website", target: "/Users/alex/Projects/Website"),
                                  Attachment(kind: .url, label: "docs.example.com", target: "https://docs.example.com/d/abc")])
                try await Snap.render("lm2r-\(id)-thread", look: look, settle: 0.6) { r.f.conversation() }
            }
        }
    }
}

extension DesignerAuditRenders {
    /// LM2-R: the proposed fixes. Settings following a fixed-appearance theme, and draft chips that wrap.
    @Test func lm2ReviewFixes() async throws {
        for look in Snap.Look.basic {
            for themeID in ["parchment", "midnight", "phosphor", "pocket"] {
                let r = LM2ReviewFixture(theme: themeID, font: look.font); defer { r.cleanup() }
                try r.addRules()
                let theme = r.f.settings.currentTheme
                try await Snap.render("lm2r-fix-\(themeID)-rules", look: look, padding: 0, settle: 0.6) { r.settings(.rules).zeusThemeAppearance(theme) }
            }
            let f = Fixture(font: look.font); defer { f.cleanup() }
            let items = [Attachment(kind: .file, label: "Q3 review.key", target: "/Users/alex/Documents/Q3 review.key"),
                         Attachment(kind: .folder, label: "Website", target: "/Users/alex/Projects/Website"),
                         Attachment(kind: .url, label: "docs.example.com", target: "https://docs.example.com/d/abc"),
                         Attachment(kind: .file, label: "Release notes draft with a long name.md", target: "/Users/alex/Documents/notes.md")]
            let pictureThumb = ImageRenderer(content: LM2MockFrame(code: true).frame(width: 96, height: 60)).nsImage.map { Image(nsImage: $0) }
            try await Snap.render("lm2r-fix-chips", look: look, settle: 0.5) {
                VStack(alignment: .leading, spacing: 8) {
                    ZeusChipFlow {
                        ForEach(items, id: \.id) { item in
                            ZeusAttachmentChip(item, actionTitle: item.kind == .folder ? "Work in this folder" : nil, onAction: {}, onRemove: {})
                        }
                        ZeusAttachmentChip(Attachment(kind: .file, label: "Picture · Xcode", target: "/tmp/picture.heic"), thumbnail: pictureThumb, onRemove: {})
                    }
                    ZeusFieldChrome(isFocused: true) { Text("Message your assistant…").zeusFont(.body) }
                }
                .padding(18).frame(width: 400).zeusDialog(tail: nil).environment(\.zeusFontChoice, .pixel)
            }
        }
    }
}

// MARK: - README: Learn from me (R6). The real Settings › Privacy pane with all four levels, What Zeus Kept with a
// picture and typing, and Rules. Synthetic records in a fixture journal under a scratch folder with a fixture key;
// nothing is captured, no permission is asked for, and no real journal, keychain or app list is read.

@MainActor private final class ReadmeLearning {
    let f: Fixture
    let journal: EncryptedJournalStore
    let policies: ObservationSettings
    let learn: LearnFromMe
    let learning: LearningPresentation
    let rules = LM2DManagedRules()
    let viewer: JournalViewerModel
    let nav = SettingsNavigation()
    /// 15:00 today: the viewer's clock, so the day reads "Today" and "days left" is stable within a day.
    let now: Date

    init() throws {
        f = Fixture(font: .pixel)
        let day = Calendar.current.startOfDay(for: Date())
        now = day.addingTimeInterval(15 * 3600)
        journal = EncryptedJournalStore(root: f.root.appendingPathComponent("journal"), keyProvider: LM2BPrivateKey())
        policies = ObservationSettings(defaults: f.defaults)
        learn = LearnFromMe(settings: LearnSettings(defaults: f.defaults), root: f.root.appendingPathComponent("activity"), source: { AuditActivitySource() })
        learn.settings.introShown = true
        learn.settings.enabled = true
        policies.edit(2) { $0.enabled = true; $0.consented = true }
        // Levels 3 and 4 show as on; without consent nothing starts capture or asks macOS.
        policies.edit(3) { $0.enabled = true; $0.consented = false }
        policies.edit(4) { $0.enabled = true; $0.consented = false
            $0.apps = [.init(name: "Mail", bundleIDs: ["com.apple.mail"]), .init(name: "Notes", bundleIDs: ["com.apple.Notes"])] }
        learning = LearningPresentation(defaults: f.defaults, learn: learn, policies: policies)
        let focus = LM2FocusSource(); focus.application = nil; focus.record = nil
        learning.install(journal: journal, rules: rules, redactor: ReviewRedactor(), source: focus)
        learning.screen?.privacy.permission = .granted
        learning.screen?.privacy.modelAvailable = true
        learning.typing?.privacy.permission = .granted
        learning.typing?.privacy.modelAvailable = true
        viewer = JournalViewerModel(journal: journal, now: now, clock: { [now] in now })
        nav.showsRules = true
        try addRecords(day: day)
        try addRules()
    }

    private func addRecords(day: Date) throws {
        func at(_ hour: Int, _ minute: Int) -> Date { day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60)) }
        func item(_ id: String, _ time: Date, _ level: JournalLevel, _ app: String?, _ kind: JournalKind, _ description: String,
                  text: String? = nil, topic: String? = nil, details: [String: String] = [:]) -> JournalItem {
            JournalItem(id: id, time: time, level: level, app: app, kind: kind,
                        payload: Redacted(JournalPayload(description: description, text: text, topic: topic, details: details)))
        }
        try journal.append(item("s1", at(8, 2), .activity, nil, .sentToAssistant, "Morning summary",
                                text: "Mostly Notes and Mail yesterday, with a long break at 12:30. Winding down around 18:00.", details: ["sessionLabel": "Claude · Zeus"]))
        try journal.append(item("f1", at(9, 41), .focus, "com.apple.mail", .focus, "Mail", text: "Window: Lunch with ‹name› on Friday"))
        // A covered picture of a drawn window: one text line covered, the photo pixellated.
        let synthetic = try Self.drawWindow()
        let boxes = [FrameBox(x: 0.04, y: 0.615, width: 0.50, height: 0.075, kind: .text), FrameBox(x: 0.62, y: 0.20, width: 0.33, height: 0.56, kind: .picture)]
        let covered = try FrameRedactor.cover(synthetic, boxes: boxes)
        let frame = Redacted(FrameItem(heic: try FrameRedactor.heic(covered), width: 1000, height: 600, boxes: boxes, appName: "TextEdit", windowTitle: "Q3 planning notes"))
        try journal.appendFrame(frame, item: item("p1", at(10, 12), .screen, "com.apple.TextEdit", .frame, "TextEdit · Q3 planning notes", details: ["window": "Q3 planning notes"]))
        try journal.append(item("d1", at(10, 12), .screen, "com.apple.TextEdit", .description, "Editing the Q3 planning notes.", details: ["frame_id": "p1", "window": "Q3 planning notes"]))
        try journal.append(item("t1", at(14, 5), .typed, "com.apple.mail", .typedText, "Typing",
                                text: "hi dr ‹name› can we move thursday to 3pm my ‹health› is still sore", topic: "Replying to a doctor about rescheduling an appointment"))
        try journal.append(item("t2", at(14, 31), .typed, "com.apple.mail", .typedText, "Typing",
                                topic: "Drafting a project update for a colleague", details: ["words_not_kept": "setting"]))
    }

    /// A generic document window, drawn here: a title bar, a heading, text lines and a colour-block "photo".
    private static func drawWindow() throws -> CGImage {
        let size = NSSize(width: 1000, height: 600)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            NSColor(white: 0.9, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1000, height: 44).fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19), .foregroundColor: NSColor(white: 0.2, alpha: 1)]
            ("Q3 planning notes" as NSString).draw(at: NSPoint(x: 40, y: 80), withAttributes: title)
            let lines = ["Goals for the quarter and who owns each one", "Budget review with the finance team on Friday",
                         "Draft the launch timeline before the offsite", "Collect open questions for the design review",
                         "Share the summary with everyone on Monday", "Follow up on the venue for the team dinner"]
            for (index, text) in lines.enumerated() { (text as NSString).draw(at: NSPoint(x: 40, y: 140 + CGFloat(index) * 40), withAttributes: body) }
            let tones = [NSColor(red: 0.93, green: 0.76, blue: 0.35, alpha: 1), NSColor(red: 0.36, green: 0.55, blue: 0.78, alpha: 1),
                         NSColor(red: 0.47, green: 0.67, blue: 0.42, alpha: 1), NSColor(red: 0.82, green: 0.45, blue: 0.38, alpha: 1)]
            for row in 0..<6 { for column in 0..<5 {
                tones[(row * 3 + column * 2 + row * column) % tones.count].setFill()
                NSRect(x: 640 + column * 62, y: 150 + row * 52, width: 62, height: 52).fill()
            } }
            return true
        }
        var rect = NSRect(origin: .zero, size: size)
        guard let native = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let raster = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileReadCorruptFile) }
        raster.draw(native, in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        guard let result = raster.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private func addRules() throws {
        let created = Date().addingTimeInterval(-3 * 86_400)
        let proposed = try rules.propose([
            RuleProposal(sentence: "Hold routine messages after 18:00", trigger: .init(time: .init(startMinute: 1080, endMinute: 540)), evidence: ["f1"]),
            RuleProposal(sentence: "Send a short update to the team when I'm late for stand-up", kind: .acts, confidence: 0.55, evidence: ["f1"])], at: created)
        guard proposed.count == 2 else { return }
        rules.ruleActions = [.init(id: "shadow", ruleID: proposed[1].id, sessionKey: "fixture", text: "would have sent “Running late, 10 min” to the team chat",
                                   undo: nil, created: created.addingTimeInterval(86_400), kind: .shadow)]
        rules.outcomeEvents = [.init(id: "o1", ruleID: proposed[0].id, at: Date().addingTimeInterval(-86_400), outcome: .accepted, source: .explicit, delta: 0.02)]
    }

    func settings(_ tab: SettingsTab) -> some View {
        nav.tab = tab
        let hub = AgentMessagingHub()
        return SettingsView(settings: f.settings, managed: ManagedAssistantModel(settings: f.settings, controller: { nil }), cards: f.store, status: f.status, messaging: hub, preview: hub,
                            testMessage: ComposeModel(cards: f.store, messaging: hub), injectDemo: { _ in }, resetPosition: {},
                            navigation: nav, login: LoginItemModel(), hotKey: GlobalHotKey(), activity: f.activity, learn: learn, learning: learning)
    }
    func kept() -> some View { JournalWindowView(model: viewer, settings: f.settings) }
    func rulesPane() -> some View { learning.rules.map { RulesSettingsView(model: $0) } }
    func cleanup() { learning.stop(); f.cleanup() }
}

extension DesignerAuditRenders {
    /// The "Zeus learns how you work" README art alone (`render.sh "readmeLearning()"`); `readme()` includes it.
    @Test func readmeLearning() async throws {
        for look in Readme.looks { try await learning(look) }
    }

    /// Settings › Privacy (all four levels), What Zeus Kept (a picture and typing) and Rules, framed like `settings()`.
    fileprivate func learning(_ look: (name: String, appearance: NSAppearance.Name)) async throws {
        let r = try ReadmeLearning(); defer { r.cleanup() }
        func framed(_ view: some View, height: CGFloat, top: CGFloat = 0) -> some View {
            view.frame(width: 792, height: height, alignment: .top).clipped().padding(.top, top).padding(.bottom, 20)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        }
        // The current Privacy pane, including the LF1 folder row and picture-covering control.
        // Give the scroll view room to lay out every control, then trim the spare space below its last action.
        let privacyHeight = CGFloat(ProcessInfo.processInfo.environment["README_PRIVACY_HEIGHT"].flatMap(Double.init) ?? 2650)
        let cut: CGFloat = 92, bottom: CGFloat = 180
        try await Readme.still("privacy-\(look.name)", appearance: look.appearance, size: CGSize(width: 792, height: privacyHeight - cut - bottom + 44), settle: 0.8,
                               framed(r.settings(.privacy).frame(width: 744, height: privacyHeight - 48).padding(24).offset(y: -cut), height: privacyHeight - cut - bottom, top: 24))
        try await Readme.still("kept-\(look.name)", appearance: look.appearance, size: CGSize(width: 792, height: 540), settle: 0.8,
                               framed(r.kept(), height: 520))
        try await Readme.still("rules-\(look.name)", appearance: look.appearance, size: CGSize(width: 792, height: 530), settle: 0.8,
                               framed(r.rulesPane().padding(24).buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle()), height: 510))
    }
}

// MARK: - UX3: the surfaces a user meets on the first day of 0.3.0 (fixture data only; renders under build/tmp/ux3)

@MainActor private final class UX3DeliverySource: LearningDeliveryPresenting {
    var pendingLearningDeliveries: [PendingLearningDelivery] = []
    var deliveryHolds: [DeliveryHold] = []
    var managedSetupStale = ManagedSetupStaleness()
    var managedTemplateReplacement: ManagedTemplateReplacement? { nil }
    func requestLearningDeliveryCancellation(deliveryID: String) {}
    func restartManagedAssistantForSetup() {}
    func replaceEditedManagedTemplates(_ snapshot: ManagedTemplateReplacement) throws {}
}

private enum UX3Text {
    static let brief = """
    Start of my day: Saturday 18 October.
    Using yesterday's summary, your Notes/, my rules, and your own tools (calendar, mail, tasks) if you have them, send me one short brief of what matters today: what's coming up, what's at risk, what you've prepared. One zeus_present with about "Morning brief": a short title, then at most 6 lines, the most important first. If nothing matters today, zeus_ack and stay quiet.
    Yesterday (from Zeus's journal, private details removed):
    - Mail
    - Calendar
    - Notes
    Unprompted messages left today: 6 (high priority doesn't count).
    Files: Zeus/rules.md
    """
    static let reflection = """
    Zeus reflection for Friday 17 October. A redacted summary of how I've used my Mac over the last 28 days, built on this Mac. It isn't a new request from me; it's your evening to learn and get ahead.

    Do these, in this order:
    1. Update your notes. Revise Notes/about-you.md (what you've concluded about me) and Notes/patterns.md (my routines and recurring tasks) from the patterns below. Date each change and say what changed your mind. Conclusions, not copies: don't paste these lines in.
    2. Propose rules, if any. Call zeus_get_rules, then zeus_propose_rules with at most three, only for a pattern that held on two or more days, each with two evidence IDs from different days taken from the lines below. Don't propose anything listed under "Don't propose again", even reworded. Acting rules start in shadow; every purchase asks.
    3. Get ahead of tomorrow. If one thing needs preparing or flagging (something due, a meeting, a reply I owe, a task I keep putting off), do the prep and send me one short message with an about label. Otherwise zeus_ack and stay quiet. Unprompted messages left today: 4 (high priority doesn't count).
    Never repeat my habits, numbers or private details back to me. A placeholder like ‹name› is something Zeus removed: don't guess it, don't ask me for it.

    Rhythm
    First activity about 09:00 every day seen (13 days). [j_a1 Mon 6 Oct, j_b2 Wed 8 Oct, j_c3 Tue 14 Oct]
    Last activity about 18:20 on weekdays, later on Fridays (19:10). Last activity is a wind-down clue, not proof you stopped. [j_d4 Fri 10 Oct, j_e5 Fri 17 Oct]
    A break of about 45 min starting near 12:30 on most days (9 days seen). [j_f6 Tue 7 Oct, j_g7 Thu 16 Oct]

    Focus
    Mornings: Mail, about 20 min (every day seen). Durations are estimates from adjacent events, capped at 15 min between them. [j_h8 Mon 6 Oct, j_i9 Mon 13 Oct]
    Afternoons: Xcode, about 2 h 30 min on weekdays. [j_j1 Tue 7 Oct, j_k2 Wed 15 Oct]
    Mondays: Calendar, about 5 min (every Monday seen). [j_l3 Mon 6 Oct, j_m4 Mon 13 Oct]

    Sequences
    Mail then Calendar within the first window, 4 of 4 Mondays. Switches within 15 minutes of each other. [j_n5 Mon 29 Sep, j_o6 Mon 13 Oct]
    Xcode then Terminal most afternoons (11 days seen). [j_p7 Thu 2 Oct, j_q8 Thu 16 Oct]

    Topics
    Release notes (6 days seen). [j_r9 Thu 9 Oct, j_s1 Thu 16 Oct]
    Design review (3 days seen, new this week). [j_t2 Tue 14 Oct, j_u3 Fri 17 Oct]

    Engagement
    Opened 4 of 5 morning briefs; rated one "Not now". [c_v4 Tue 14 Oct, c_w5 Thu 16 Oct]
    Ignored both notes about a later start. [c_x6 Wed 8 Oct, c_y7 Wed 15 Oct]

    Today vs usual
    Today started 40 min later than usual (09:40 against about 09:00).
    More time in Calendar than usual (25 min against about 5 min).

    Today, last records (at most 20)
    17:52 Xcode
    18:05 Terminal
    18:14 Mail
    18:31 Notes

    Rule outcomes since the last reflection
    None.

    Don't propose again
    Hold routine messages after 18:00 on weekdays (retired 12 Oct).

    Message preferences
    Fewer notes about a later start.
    Files: Zeus/rules.md, Zeus/reflections/2026-10-17.md
    """
}

extension DesignerAuditRenders {
    /// UX3: fresh-eyes audit renders. Nothing here reads the user's Mac; stores and capture are the LM2 fakes.
    @Test func ux3() async throws {
        let previousOut = Snap.out
        Snap.out = Snap.repo.appendingPathComponent(ProcessInfo.processInfo.environment["UX_RENDER_DIR"] ?? "build/tmp/ux3")
        defer { Snap.out = previousOut }
        let now = Date()
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        for look in Snap.Look.basic {
            // 1. The conversation on the morning of day two: yesterday's brief request was superseded by today's, but its line still says "ready".
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                f.messaging.sessions = [AuditMessaging.claude]
                f.store.recordLearningNotice(.init(id: "n_brief_yesterday", kind: .reflection, createdAt: at(-1440 - 12),
                    summary: "Morning brief request ready for your assistant", actionTitle: "View", detail: UX3Text.brief, ruleID: nil), action: nil)
                f.store.recordLearningNotice(.init(id: "n_d_reflection_yesterday", kind: .reflection, createdAt: at(-870),
                    summary: "Daily reflection ready", actionTitle: "View", detail: UX3Text.reflection, ruleID: nil), action: nil)
                f.store.recordLearningNotice(.init(id: "n_brief_today", kind: .reflection, createdAt: at(-14),
                    summary: "Morning brief request ready for your assistant", actionTitle: "View", detail: UX3Text.brief, ruleID: nil), action: nil)
                f.store.recordLearningNotice(.init(id: "learning-delivery-hold:brief_today", kind: .reflection, createdAt: at(-14),
                    summary: "Zeus is waiting to deliver to your assistant: it isn't connected", actionTitle: "Start Assistant", detail: nil, ruleID: nil), action: {})
                try await Snap.render("ux3-thread-day2", look: look, padding: 0, settle: 0.8) { f.conversation() }
            }
            // 2. The reflection's "View" in the thread: the whole request inline, in caption type, with no bound.
            do {
                let notice = ThreadNotice(id: "n_r", kind: .learning, createdAt: at(-5), summary: "Sent a daily reflection", actionTitle: "View", detail: UX3Text.reflection)
                let host = try await Snap.render("ux3-reflection-collapsed", look: look, padding: 12, settle: 0.5) {
                    ConversationNoticeLine(notice: notice, maxWidth: 340, hasAction: false, perform: {}).frame(width: 356)
                        .environment(\.zeusFontChoice, look.font)
                }
                func axFind(_ element: Any, label: String, depth: Int = 0) -> AnyObject? {
                    guard depth < 60 else { return nil }
                    let object = element as AnyObject
                    if let found = object.accessibilityLabel?() ?? nil, found == label { return object }
                    for child in (object.accessibilityChildren?() ?? nil) ?? [] {
                        if let hit = axFind(child, label: label, depth: depth + 1) { return hit }
                    }
                    return nil
                }
                if let view = axFind(host, label: "View: Sent a daily reflection"), view.accessibilityPerformPress?() == true {
                    try await Task.sleep(for: .seconds(0.6))
                    host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .seconds(0.3))
                    try Snap.write(host, name: "ux3-reflection-expanded__\(look)")
                } else {
                    // Stand-in when the hosted button isn't reachable through accessibility: the detail block exactly as
                    // ConversationNoticeLine lays it out (caption type, field background), to show the expanded height.
                    Snap.log.append("ux3-reflection-expanded: View button not found through accessibility; rendering the detail block as a stand-in")
                    try await Snap.render("ux3-reflection-expanded-standin", look: look, padding: 12, settle: 0.5) {
                        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
                            ConversationNoticeLine(notice: .init(id: "n_r2", kind: .learning, createdAt: at(-5), summary: "Sent a daily reflection", actionTitle: "Hide", detail: nil), maxWidth: 340, hasAction: true, perform: {})
                            Text(UX3Text.reflection).zeusFont(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .padding(ZeusTheme.Spacing.s).background(Color(nsColor: .textBackgroundColor))
                                .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: ZeusTheme.pixel))
                        }.frame(width: 356, alignment: .leading).environment(\.zeusFontChoice, look.font)
                    }
                }
            }
            // 3. The Sent ledger: Waiting rows for today's brief and yesterday's reflection, and Received rows that mix nouns with sentences.
            let r = LM2ReviewFixture(theme: "classic", font: look.font); defer { r.cleanup() }
            let viewer = try #require(r.learning.viewer)
            func sent(_ id: String, _ minutes: Double, _ kind: String, _ summary: String, _ text: String) -> JournalItem {
                JournalItem(id: id, time: at(minutes), level: .activity, app: nil, kind: .sentToAssistant,
                    payload: Redacted(JournalPayload(description: summary, text: text, details: ["kind": kind, "sessionLabel": "Claude · Zeus", "delivery_id": id])))
            }
            r.journal.records = [
                sent("sent:digest_today", -35, "digest", "Morning summary", "Mostly Xcode (4 h 10 min) and Mail. Away 12:30–13:15."),
                sent("sent:brief_day0", -33, "brief", "Sent the morning brief request", UX3Text.brief),
                sent("sent:rating_1", -30, "rating", "Sent your message preference", "Fewer notes about a later start."),
            ]
            let src = UX3DeliverySource()
            let deliveries = LearningDeliveryModel(cards: r.f.store, source: { src })
            deliveries.canStart = { true }
            src.pendingLearningDeliveries = [
                .init(id: "brief_today", kind: .brief, text: UX3Text.brief, preparedAt: at(-14), sessionLabel: "Claude · Zeus"),
                .init(id: "d_reflection_yesterday", kind: .reflection, text: UX3Text.reflection, preparedAt: at(-870), sessionLabel: "Claude · Zeus"),
            ]
            src.deliveryHolds = [
                .init(deliveryID: "brief_today", kind: .brief, since: at(-14), reason: .disconnected),
                .init(deliveryID: "d_reflection_yesterday", kind: .reflection, since: at(-870), reason: .disconnected),
            ]
            r.learning.deliveries = deliveries
            deliveries.start(); defer { deliveries.stop() }
            viewer.sentOnly = true; viewer.reload()
            try await Snap.render("ux3-ledger-waiting", look: look, padding: 0, size: CGSize(width: 720, height: 600), settle: 0.6) {
                JournalWindowView(model: viewer, settings: r.f.settings).background(Color(nsColor: .windowBackgroundColor))
            }
            // 4. After the supersession and before anything was received today: the ledger says "Nothing yet" while the thread says "ready".
            src.pendingLearningDeliveries = []; src.deliveryHolds = []; deliveries.reconcile()
            r.journal.records = []; viewer.reload()
            try await Snap.render("ux3-ledger-after-supersede", look: look, padding: 0, size: CGSize(width: 720, height: 300), settle: 0.6) {
                JournalWindowView(model: viewer, settings: r.f.settings).background(Color(nsColor: .windowBackgroundColor))
            }
            // 5. Learn from me off, morning brief on: the ledger promises nothing will be sent; the Assistant pane asks for a brief.
            viewer.learningEnabled = { false }; viewer.reload()
            try await Snap.render("ux3-ledger-learning-off", look: look, padding: 0, size: CGSize(width: 720, height: 300), settle: 0.6) {
                JournalWindowView(model: viewer, settings: r.f.settings).background(Color(nsColor: .windowBackgroundColor))
            }
            let brief = MorningBriefSettings(defaults: r.f.defaults); brief.enabled = true
            try await Snap.render("ux3-settings-assistant", look: look, padding: 0, settle: 0.6) { r.settings(.agent, morningBrief: brief) }
            // 6. Settings › Privacy with Learn from me on, then off: the lower controls look live either way.
            r.learn.setEnabled(true)
            try await Snap.render("ux3-settings-privacy-on", look: look, padding: 0, settle: 0.6) { r.settings(.privacy) }
            r.learn.setEnabled(false)
            try await Snap.render("ux3-settings-privacy-off", look: look, padding: 0, settle: 0.6) { r.settings(.privacy) }
            // 7. Delete Everything's confirmation.
            try await Snap.render("ux3-delete-sheet", look: look, padding: 0, settle: 0.5) {
                DeleteLearningConfirmation(includeAssistantNotes: .constant(false), cancel: {}, delete: {})
                    .environment(\.zeusTheme, r.f.settings.currentTheme).environment(\.zeusFontChoice, .system)
                    .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).background(Color(nsColor: .windowBackgroundColor))
            }
        }
        try Snap.dump("ux3-log", Snap.log.joined(separator: "\n"))
    }
}

extension DesignerAuditRenders {
    /// UX5: Settings say everything Zeus sends. Before/after renders go under build/tmp/ux5/<UX_RENDER_DIR>.
    @Test func ux5() async throws {
        let previousOut = Snap.out
        Snap.out = Snap.repo.appendingPathComponent(ProcessInfo.processInfo.environment["UX_RENDER_DIR"] ?? "build/tmp/ux5/after")
        defer { Snap.out = previousOut }
        for look in Snap.Look.basic {
            let r = LM2ReviewFixture(theme: "classic", font: look.font); defer { r.cleanup() }
            let brief = MorningBriefSettings(defaults: r.f.defaults); brief.enabled = true
            r.learn.setEnabled(true)
            try await Snap.render("ux5-settings-privacy-on", look: look, padding: 0, settle: 0.6) { r.settings(.privacy, morningBrief: brief) }
            r.learn.setEnabled(false)
            try await Snap.render("ux5-settings-privacy-off", look: look, padding: 0, settle: 0.6) { r.settings(.privacy, morningBrief: brief) }
            try await Snap.render("ux5-settings-assistant", look: look, padding: 0, settle: 0.6) { r.settings(.agent, morningBrief: brief) }
            if let viewer = r.learning.viewer {
                r.journal.records = []; viewer.sentOnly = true
                viewer.learningEnabled = { false }; viewer.briefEnabled = { true }; viewer.reload()
                try await Snap.render("ux5-ledger-learning-off-brief-on", look: look, padding: 0, size: CGSize(width: 720, height: 300), settle: 0.6) {
                    JournalWindowView(model: viewer, settings: r.f.settings).background(Color(nsColor: .windowBackgroundColor))
                }
                viewer.briefEnabled = { false }; viewer.reload()
                try await Snap.render("ux5-ledger-learning-off", look: look, padding: 0, size: CGSize(width: 720, height: 300), settle: 0.6) {
                    JournalWindowView(model: viewer, settings: r.f.settings).background(Color(nsColor: .windowBackgroundColor))
                }
            }
            try await Snap.render("ux5-folder-connect-own-no-journal", look: look, padding: 16, settle: 0.5) {
                LearningFolderView(model: LearningFolderModel(provider: nil), managed: false).frame(width: 600)
                    .environment(\.zeusTheme, r.f.settings.currentTheme).environment(\.zeusFontChoice, .system)
                    .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).background(Color(nsColor: .windowBackgroundColor))
            }
            try await Snap.render("ux5-intro-sheet", look: look, padding: 0, settle: 0.5) {
                LearnIntroSheet(turnOn: {}, notNow: {}).environment(\.zeusTheme, r.f.settings.currentTheme)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        try Snap.dump("ux5-log", Snap.log.joined(separator: "\n"))
    }
}

extension DesignerAuditRenders {
    /// HUNT2 (designer): the panel after a week of quiet lines, and the strip waiting on a pile of present cards.
    @Test func hunt2() async throws {
        let previousOut = Snap.out
        Snap.out = Snap.repo.appendingPathComponent(ProcessInfo.processInfo.environment["UX_RENDER_DIR"] ?? "build/tmp/hunt2")
        defer { Snap.out = previousOut }
        let s = AuditMessaging.claude.sessionKey
        for look in Snap.Look.basic {
            // A. Seven days in which the user spoke twice: every other line is Zeus's own housekeeping.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                f.messaging.sessions = [AuditMessaging.claude]
                let day0 = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-6 * 86_400)
                for day in 0..<7 {
                    func at(_ hour: Double) -> Date { day0.addingTimeInterval(Double(day) * 86_400 + hour * 3_600) }
                    let d = "d\(day)"
                    f.store.recordLearningNotice(.init(id: "n_digest_\(d)", kind: .reflection, createdAt: at(9.0), summary: "Sent the morning summary", actionTitle: "View", detail: "Mostly Xcode and Mail.", ruleID: nil), action: nil)
                    f.store.recordLearningNotice(.init(id: "n_brief_\(d)", kind: .reflection, createdAt: at(9.05), summary: "Sent the morning brief request", actionTitle: "View", detail: UX3Text.brief, ruleID: nil), action: nil)
                    if day % 3 != 1 {
                        f.store.add(Card(id: "c_brief_\(d)", kind: .content, title: "Today", body: "Design review at 15:00. The release notes draft is ready for a look.", sessionKey: s, createdAt: at(9.2), updatedAt: at(9.2), about: "Morning brief", origin: .unprompted))
                    }
                    f.store.recordLearningNotice(.init(id: "n_note_\(d)", kind: .reflection, createdAt: at(9.5), summary: "Sent a note: first activity today", actionTitle: "View", detail: "First activity today at 09:30.", ruleID: nil), action: nil)
                    if day == 2 {
                        f.store.add(Card(id: "u_\(d)", kind: .userMessage, body: "Can you move the review to Thursday?", createdAt: at(10), updatedAt: at(10)))
                        f.store.add(Card(id: "c_reply_\(d)", kind: .message, body: "Done: Thursday 15:00, invite updated.", sessionKey: s, createdAt: at(10.1), updatedAt: at(10.1), origin: .reply))
                    }
                    if day == 5 {
                        f.store.add(Card(id: "u_\(d)", kind: .userMessage, body: "Thanks, looks good.", createdAt: at(14), updatedAt: at(14)))
                    }
                    f.store.recordLearningNotice(.init(id: "n_note2_\(d)", kind: .reflection, createdAt: at(17.6), summary: "Sent a note: day winding down", actionTitle: "View", detail: "Day winding down.", ruleID: nil), action: nil)
                    f.store.recordLearningNotice(.init(id: "n_refl_\(d)", kind: .reflection, createdAt: at(18.7), summary: "Sent the evening reflection", actionTitle: "View", detail: UX3Text.reflection, ruleID: nil), action: nil)
                }
                f.store.markAllSeen()
                try await Snap.render("hunt2-week-of-lines", look: look, padding: 0, settle: 0.8) { f.conversation() }
            }
            // B. Thirty unanswered present cards: the strip waits on "30 questions" and the avatar waits.
            do {
                let f = Fixture(font: look.font); defer { f.cleanup() }
                f.messaging.sessions = [AuditMessaging.claude]
                for day in 0..<30 {
                    let at = t0.addingTimeInterval(Double(day - 30) * 86_400)
                    f.store.add(Card(id: "c_p\(day)", kind: .content, title: "Prepared for today", body: "Draft \(day + 1) of the status update is in your folder.",
                                     options: [CardOption(id: "ok", label: "Looks good", style: .primary), CardOption(id: "rev", label: "Revise")],
                                     sessionKey: s, createdAt: at, updatedAt: at, about: "Prepared work", origin: .unprompted))
                }
                f.store.markAllSeen()
                try await Snap.render("hunt2-thirty-present-cards", look: look, padding: 0, settle: 0.8) { f.conversation() }
            }
        }
        try Snap.dump("hunt2-log", Snap.log.joined(separator: "\n"))
    }
}

extension DesignerAuditRenders {
    /// FX16: thirty unanswered present cards and the strip says Idle; no "?" anywhere.
    @Test func fx16() async throws {
        let previousOut = Snap.out
        Snap.out = Snap.repo.appendingPathComponent(ProcessInfo.processInfo.environment["UX_RENDER_DIR"] ?? "build/tmp/fx16")
        defer { Snap.out = previousOut }
        let s = AuditMessaging.claude.sessionKey
        for look in Snap.Look.basic {
            let f = Fixture(font: look.font); defer { f.cleanup() }
            f.messaging.sessions = [AuditMessaging.claude]
            for day in 0..<30 {
                let at = t0.addingTimeInterval(Double(day - 30) * 86_400)
                f.store.add(Card(id: "c_p\(day)", kind: .content, title: "Prepared for today", body: "Draft \(day + 1) of the status update is in your folder.",
                                 options: [CardOption(id: "ok", label: "Looks good", style: .primary), CardOption(id: "rev", label: "Revise")],
                                 sessionKey: s, createdAt: at, updatedAt: at, about: "Prepared work \(day)", origin: .unprompted))
            }
            f.store.markAllSeen()
            try await Snap.render("fx16-thirty-present-cards", look: look, padding: 0, settle: 0.8) { f.conversation() }
            // After the user replies, every hand-over's actions have closed quietly.
            f.store.add(Card(id: "u_1", kind: .userMessage, body: "Thanks, all good.", createdAt: t0, updatedAt: t0, status: .answered))
            f.store.closeOpenHandovers()
            try await Snap.render("fx16-after-reply", look: look, padding: 0, settle: 0.8) { f.conversation() }
        }
        try Snap.dump("fx16-log", Snap.log.joined(separator: "\n"))
    }
}
