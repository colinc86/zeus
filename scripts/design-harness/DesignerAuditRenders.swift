// Q2 visual-audit harness (designer). NOT part of the app's test suite.
// docs/audit/harness/render.sh copies this file into Zeus/App/Tests, runs only this suite, and removes it again.
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
    var managedTmuxSessionName: String? { managedStatus == .off ? nil : "zeus" }
    var managedAttachCommand: String? { managedTmuxSessionName.map { "tmux attach -t \($0)" } }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        agent == .opencode ? [] : ManagedAgentLaunch.policies(for: agent).map(\.mode)
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? {
        if missingTmux { return "Not installed: tmux (brew install tmux). Install it, then press Check Again." }
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
    static let out = repo.appendingPathComponent("build/q2-renders")
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
            lines.append(String(repeating: "  ", count: depth) + "[\(role)] label=\"\(label)\" title=\"\(title)\" value=\"\(value)\"" + (help.isEmpty ? "" : " help=\"\(help)\""))
        }
        for child in (object.accessibilityChildren?() ?? nil) ?? [] { axTree(child, depth: depth + 1, into: &lines) }
    }
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
                                            navigation: nav, login: LoginItemModel(), hotKey: GlobalHotKey(), activity: f.activity)
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
