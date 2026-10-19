import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class AvailabilityController: ManagedSessionControlling, AgentMessaging {
    var managedStatus: ManagedSessionStatus = .off
    var managedTmuxSessionName: String? { nil }
    var managedAttachCommand: String? { nil }
    var sessions: [ConnectedSession] { [] }
    var installed = Set(ManagedAssistantModel.agents)
    var tmuxInstalled = false
    var starts = 0
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        installed.contains(agent) ? [.init(id: "ask", title: "Ask first", detail: "Native permissions", isUnrestricted: false, isDefault: true)] : []
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? {
        ManagedSessionController.requirementsMessage(missingTmux: !tmuxInstalled, missingAgent: installed.contains(agent) ? nil : agent)
    }
    func startManagedSession() { starts += 1 }
    func stopManagedSession() {}
    func restartManagedSession() {}
    func startNewManagedConversation() {}
    func openManagedSessionInTerminal() {}
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}

@MainActor private final class AvailabilityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private struct AvailabilityPasswords: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}

@MainActor private final class AvailabilityFixture {
    let suite = TestDefaults.suite("zeus-availability")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-availability-\(UUID())")
    let defaults: UserDefaults
    let settings: AppSettings
    let controller = AvailabilityController()
    let cards: CardStore
    let hub = AgentMessagingHub()
    let model: ManagedAssistantModel
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: AvailabilityPasswords())
        settings.talkHotKey.enabled = false
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let controller = controller
        hub.runtime = controller
        model = ManagedAssistantModel(settings: settings, controller: { controller })
        model.refreshAvailability()
        model.chooseFolder(root.path)
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Suite(.serialized) struct AssistantAvailabilityTests {
    @Test func missingPrerequisitesKeepRecoveryAvailable() throws {
        let f = try AvailabilityFixture(); defer { f.cleanup() }
        #expect(f.model.note?.contains("press Check Again") == true)
        #expect(f.model.showsCheckAgain && !f.model.canStart)
        f.controller.tmuxInstalled = true
        f.model.refreshAvailability()
        #expect(!f.model.showsCheckAgain && f.model.canStart)
        f.controller.installed.remove(.opencode)
        f.model.refreshAvailability()
        #expect(f.model.showsCheckAgain && f.model.canStart)
        let unavailable = ManagedAssistantModel(settings: f.settings, controller: { nil })
        unavailable.refreshAvailability()
        #expect(!unavailable.showsCheckAgain)
    }

    @Test func checkAgainButtonRefreshesAfterInstallingTmux() async throws {
        let f = try AvailabilityFixture(); defer { f.cleanup() }
        ZeusFonts.registerBundled()
        let host = TestHostingView(rootView: AssistantSettingsView(settings: f.settings, managed: f.model, messaging: f.hub,
                testMessage: ComposeModel(cards: f.cards, messaging: f.hub)).padding(24).frame(width: 720, height: 1800, alignment: .topLeading).environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system))
        let window = AvailabilityPanel(contentRect: .init(x: -20000, y: -20000, width: 720, height: 1800),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let nodes = Self.nodes(host)
        let button = try #require(nodes.first { Self.label($0) == "Check Again" })
        #expect(!f.model.canStart && f.model.disabledActions.contains(.start))
        f.controller.tmuxInstalled = true
        #expect((button as AnyObject).accessibilityPerformPress?() == true)
        #expect(f.model.canStart && !f.model.disabledActions.contains(.start))
        f.model.perform(.start)
        #expect(f.controller.starts == 1)
    }

    @Test func appActivationRechecksInstallationWithoutStartingAssistant() throws {
        let f = try AvailabilityFixture(); defer { f.cleanup() }
        let shell = ShellController(defaults: f.defaults, cards: f.cards, settings: f.settings, requirePrivateJournal: true)
        shell.messaging.runtime = f.controller
        shell.managed.refreshAvailability()
        defer { shell.stop() }
        #expect(!shell.managed.canStart)
        let delegate = ZeusAppDelegate(); delegate.shell = shell
        f.controller.tmuxInstalled = true
        delegate.applicationDidBecomeActive(.init(name: NSApplication.didBecomeActiveNotification))
        #expect(shell.managed.canStart && !shell.managed.showsCheckAgain)
        #expect(f.controller.starts == 0)
    }

    private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject, depth: Int) -> [NSObject] {
            guard depth < 64, seen.count < 2048, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children: [Any]
            if let accessible = node as? any NSAccessibilityProtocol { children = accessible.accessibilityChildren() ?? [] }
            else {
                let selector = NSSelectorFromString("accessibilityChildren")
                children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
            }
            return [node] + children.compactMap { $0 as? NSObject }
                .flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
    private static func label(_ node: NSObject) -> String? {
        if let accessible = node as? any NSAccessibilityProtocol { return accessible.accessibilityLabel() }
        let selector = NSSelectorFromString("accessibilityLabel")
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
    }
}
