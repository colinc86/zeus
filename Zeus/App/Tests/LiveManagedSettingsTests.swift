import AppKit
import Foundation
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private struct LiveNoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}

/// Inspects in-process AX in offscreen nonactivating panels; no AX permission or posted input.
@MainActor private func liveAXNodes(_ object: Any) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    func collect(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
        let legacy = node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXChildren")?.takeUnretainedValue() as? [Any] ?? []
        let contents = node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXContents")?.takeUnretainedValue() as? [Any] ?? []
        let subviews = (node as? NSView)?.subviews ?? []
        return [node] + (children + legacy + contents + subviews).flatMap(collect)
    }
    return collect(object)
}
@MainActor private func liveAXString(_ node: NSObject, _ name: String) -> String? {
    let selector = NSSelectorFromString(name)
    let modern = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
    let attributes = ["accessibilityRole": "AXRole", "accessibilityLabel": "AXDescription", "accessibilityTitle": "AXTitle", "accessibilityValue": "AXValue"]
    let legacy = attributes[name].flatMap { attribute in
        node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?.takeUnretainedValue() as? String
    }
    return legacy ?? modern
}
@MainActor private func liveAXDescription(_ node: NSObject) -> String {
    ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { liveAXString(node, $0) }.joined(separator: " | ")
}

@MainActor private final class LiveManagedFixture {
    let suite = "zeus-live-managed-\(UUID())"
    let defaults: UserDefaults
    let root: URL
    let settings: AppSettings
    let controller = TruthManagedController()
    let model: ManagedAssistantModel
    let hub = AgentMessagingHub()
    let cards: CardStore
    private var windows: [NSPanel] = []
    init(legacy: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        if legacy {
            defaults.set(true, forKey: "general.welcomeShown")
            defaults.set("opencode", forKey: "agent.backend")
            defaults.set("opencode:/fixture#123.456", forKey: "agent.assistantSessionKey")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-live-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: LiveNoCredentials())
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let controller = controller
        model = ManagedAssistantModel(settings: settings, controller: { controller })
        hub.runtime = controller
        model.refreshAvailability()
    }
    func host<V: View>(_ view: V, height: CGFloat = 1300) -> TestHostingView {
        let host = TestHostingView(rootView: AnyView(view.environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system).frame(width: 520)))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: height)
        let window = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: 520, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        return host
    }
    func assistantHost() -> TestHostingView {
        host(AssistantSettingsView(settings: settings, managed: model, messaging: hub,
            testMessage: ComposeModel(cards: cards, messaging: hub)))
    }
    func settle(_ host: NSView) async throws {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    func cleanup() {
        model.createFolder = nil
        for window in windows { window.orderOut(nil); window.contentView = nil; window.close() }
        windows.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) @MainActor struct LiveManagedSettingsTests {
    @Test func escapeKeepsTheManagedAgentRunningButSelectsConnectYourOwn() async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        f.model.update { $0.folder = "/fixture" }
        f.settings.managedLaunchedConfig = f.model.config
        f.controller.managedStatus = .running(.idle)
        f.controller.managedTmuxSessionName = "zeus"
        f.controller.managedAttachCommand = "tmux attach -t zeus"
        f.model.chooseManaged(false)
        let host = f.host(AssistantSettingsView(settings: f.settings, managed: f.model, messaging: f.hub,
            testMessage: ComposeModel(cards: f.cards, messaging: f.hub)).background(ZeusPalette.for(.light).panel))
        try await f.settle(host)
        let labels = liveAXNodes(host).map(liveAXDescription)
        #expect(labels.contains { $0.contains("Stop the Zeus-run agent?") })
        #expect(labels.contains { $0.contains("Keep Running") })
        if ProcessInfo.processInfo.environment["ZEUS_CY1_RENDER"] == "1" {
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { root.deleteLastPathComponent() }
            let evidence = root.appendingPathComponent("TestFixtures/live/cy1")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try png.write(to: evidence.appendingPathComponent("mode-confirmation.png"))
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: host.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(host.window?.performKeyEquivalent(with: event) == true)
        try await f.settle(host)
        #expect(!f.model.enabled && f.model.confirmation == nil && f.controller.managedStatus == .running(.idle))
        #expect(f.model.retainedSessionNotice == "Your Zeus-run agent is still running in tmux (tmux attach -t zeus)")
        #expect(liveAXNodes(host).contains { liveAXDescription($0).contains("Your Zeus-run agent is still running") })
        if ProcessInfo.processInfo.environment["ZEUS_CY1_RENDER"] == "1" {
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { root.deleteLastPathComponent() }
            try #require(image.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("TestFixtures/live/cy1/keep-running-notice.png"))
        }
        f.controller.managedStatus = .stopped; try await f.settle(host)
        #expect(f.model.retainedSessionNotice == nil)
    }

    @Test func switchConfirmationOffersLaterAndEscapeKeepsTheRunningConversation() async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        f.model.update { $0.folder = "/fixture" }
        f.settings.managedLaunchedConfig = f.model.config
        f.controller.managedStatus = .running(.idle)
        f.model.chooseAgent(.codex)
        let host = f.assistantHost(); try await f.settle(host)
        #expect(f.model.confirmation == .switchConversation)
        let labels = liveAXNodes(host).map(liveAXDescription)
        #expect(labels.contains { $0.contains("Switch Now") })
        #expect(labels.contains { $0.contains("Later") })
        #expect(labels.contains { $0.contains("Claude Code's conversation stays in /fixture") })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: host.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(host.window?.performKeyEquivalent(with: event) == true)
        try await f.settle(host)
        #expect(f.model.confirmation == nil && f.controller.fresh == 0 && f.model.agentName == "Claude Code")
        #expect(f.model.needsNewConversation, "Later saves the preference without replacing the conversation")
        if ProcessInfo.processInfo.environment["ZEUS_S3_RENDER"] == "1" {
            f.model.perform(.restart); try await f.settle(host)
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { root.deleteLastPathComponent() }
            try png.write(to: root.appendingPathComponent("build/s3/settings-switch.png"))
        }
    }
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func pendingAgentCopyNamesTheSelectionWithoutRelabelingTheRunningAssistant(selected: AgentKind) async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        let running: AgentKind = selected == .claude ? .opencode : .claude
        f.model.update { $0.agent = running; $0.folder = "/fixture" }
        f.settings.managedLaunchedConfig = f.model.config
        f.controller.managedStatus = .running(.idle)
        f.model.chooseAgent(selected)
        f.model.perform(.newConversation)
        let host = f.assistantHost(); try await f.settle(host)
        let labels = liveAXNodes(host).map(liveAXDescription)
        let selectedName = ManagedAssistantModel.name(selected), runningName = ManagedAssistantModel.name(running)
        #expect(labels.contains { $0.contains("\(selectedName)'s own modes.") })
        #expect(labels.contains { $0.contains("Start a new conversation? \(selectedName) starts fresh") })
        #expect(!labels.contains { $0.contains("\(runningName)'s own modes.") || $0.contains("\(runningName) starts fresh") })
        #expect(f.model.agentName == runningName && f.controller.fresh == 0)
        f.model.cancelConfirmation()
        let mode = ManagedPermissionMode(id: "full", title: "Unrestricted", detail: "Fixture", isUnrestricted: true, isDefault: false)
        f.model.confirmation = .unrestricted(mode)
        // The unrestricted warning is also about the selected agent's permission mode.
        try await f.settle(host)
        #expect(liveAXNodes(host).contains { liveAXDescription($0).contains("\(mode.title) lets \(selectedName) run") })
    }

    @Test func escapeCancelsFreshConversationWithoutStartingAnAgent() async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        f.model.chooseFolder("/fixture")
        f.model.perform(.newConversation)
        let host = f.assistantHost(); try await f.settle(host)
        #expect(f.model.confirmation == .newConversation)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: host.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        // Dispatch only to our offscreen fixture window, never through NSApp or global input.
        #expect(host.window?.performKeyEquivalent(with: event) == true)
        try await f.settle(host)
        #expect(f.model.confirmation == nil && f.controller.fresh == 0 && f.controller.starts == 0)
    }

    @Test func oldRoutingAndWelcomeDoNotHideManagedSetupOrStartAnAgent() throws {
        let f = try LiveManagedFixture(legacy: true); defer { f.cleanup() }
        f.controller.sessions = [.init(id: UUID(), sessionKey: "opencode:/fixture#123.456", agent: .opencode, cwd: "/fixture", clientName: nil, supportsChannel: false, tmuxPane: nil, connectedAt: Date())]
        #expect(f.model.enabled && f.model.config.folder.isEmpty && !f.model.config.startWhenZeusOpens)
        #expect(f.settings.backend == .opencode && f.settings.assistantSessionKey == "opencode:/fixture#123.456")
        #expect(f.controller.starts == 0)
        #expect(AssistantSettingsView.setupChoices.map(\.id) == [true, false])
        #expect(AssistantSettingsView.setupChoices.first?.title == "Zeus runs it")
        #expect(AssistantSettingsView.setupChoices.allSatisfy { $0.detail?.isEmpty == false })
        f.model.chooseManaged(false)
        #expect(!f.model.enabled)
        let restored = AppSettings(defaults: f.defaults, userDirectory: nil, passwordStore: LiveNoCredentials())
        #expect(restored.managedSession?.enabled == false)
        #expect(restored.backend == .opencode && restored.assistantSessionKey == "opencode:/fixture#123.456")
    }

    @Test func folderFieldTracksCreateAndChooseInItsNativeAccessibilityTree() async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        let host = f.assistantHost(); try await f.settle(host)
        #expect(liveAXNodes(host).contains { liveAXDescription($0).contains("Choose a folder") })
        f.model.createFolder = { f.root }
        f.model.createDefaultFolder(); try await f.settle(host)
        #expect(liveAXNodes(host).contains { liveAXDescription($0).contains(f.root.path) })
        let chosen = f.root.appendingPathComponent("Chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        f.model.chooseFolder(chosen.path); try await f.settle(host)
        #expect(liveAXNodes(host).contains { liveAXDescription($0).contains(chosen.path) })
        #expect(f.settings.managedSession?.folder == chosen.path)
    }
    @Test func settingsTabsHaveNativeNames() async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        let navigation = SettingsNavigation()
        let host = f.host(SettingsTabBar(navigation: navigation), height: 80)
        try await f.settle(host)
        let nodes = liveAXNodes(host)
        for tab in navigation.tabs {
            #expect(nodes.contains { liveAXString($0, "accessibilityRole") == "AXButton" && liveAXDescription($0).contains(tab.rawValue) })
        }
    }

    @Test func sharedButtonChoiceAndCheckboxStylesExposeNativeNames() async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        let host = f.host(VStack {
            Button("Styled Primary") {}.buttonStyle(ZeusButtonStyle(.primary))
            Button("Styled Secondary") {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small))
            Button("Styled Destructive") {}.buttonStyle(ZeusButtonStyle(.destructive))
            ZeusChoiceList([ZeusChoice(id: true, title: "Fixture Choice", detail: "A clear description")], selection: .constant(true))
            Toggle("Fixture Checkbox", isOn: .constant(true)).toggleStyle(ZeusCheckboxStyle())
        }, height: 360)
        try await f.settle(host)
        let nodes = liveAXNodes(host)
        for name in ["Styled Primary", "Styled Secondary", "Styled Destructive", "Fixture Choice", "Fixture Checkbox"] {
            #expect(nodes.contains { liveAXDescription($0).contains(name) })
        }
    }


    @Test func managedAndGeneralPanesExposeTheirControlNames() async throws {
        let f = try LiveManagedFixture(); defer { f.cleanup() }
        f.model.createFolder = { f.root }
        let host = f.assistantHost(); try await f.settle(host)
        let labels = liveAXNodes(host).map(liveAXDescription)
        for name in ["Zeus runs it", "Connect your own", "Claude Code", "Choose Folder", "Create one for me", "Ask", "Start when Zeus opens", "Quiet hours"] {
            #expect(labels.contains { $0.contains(name) })
        }
        let generalHost = f.host(GeneralSettingsView(settings: f.settings, login: LoginItemModel(), hotKey: GlobalHotKey(), cards: f.cards)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle()))
        try await f.settle(generalHost)
        let general = liveAXNodes(generalHost).map(liveAXDescription)
        for name in ["Talk to Zeus shortcut", "Typewriter reveal", "Retro blip sound", "Reset to Option-Command-Z"] {
            #expect(general.contains { $0.contains(name) })
        }
    }
}
