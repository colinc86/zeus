import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor @Observable private final class UpdateUIController: ManagedSessionControlling, ManagedSettingsApplying, ManagedAgentUpdating {
    var managedStatus: ManagedSessionStatus = .running(.idle)
    var managedTmuxSessionName: String? = "fixture"
    var managedAttachCommand: String? = "fixture attach"
    var managedAppliedConfiguration: ManagedSessionConfig?
    var managedSettingsApplication: ManagedSettingsApplication?
    var managedSettingsApplicationError: String?
    var managedCanResumeSettings = true
    var managedAgentUpdatePending = false
    var managedAgentUpdateConversationID: String? = "fixture-conversation"
    var requests = 0
    var unsafeRestarts = 0
    func restartManagedAgentForUpdate() {
        guard let configuration = managedAppliedConfiguration else { return }
        requests += 1
        managedSettingsApplication = .init(id: UUID(), configuration: configuration, kind: .agentUpdate)
    }
    func supportsInstructionChangesOnResume(for agent: AgentKind) -> Bool { true }
    func applyManagedSettings(_ configuration: ManagedSessionConfig) {}
    func switchManagedSettings(_ configuration: ManagedSessionConfig) {}
    func cancelManagedSettingsApplication() { managedSettingsApplication = nil }
    func permissionModes(for agent: AgentKind) -> [ManagedPermissionMode] {
        [.init(id: "ask", title: "Ask first", detail: "Ask", isUnrestricted: false, isDefault: true),
         .init(id: "full", title: "Unrestricted", detail: "Full", isUnrestricted: true, isDefault: false)]
    }
    func managedRequirementsProblem(for agent: AgentKind) -> String? { nil }
    func startManagedSession() {}
    func stopManagedSession() {}
    func restartManagedSession() { unsafeRestarts += 1 }
    func startNewManagedConversation() { unsafeRestarts += 1 }
    func openManagedSessionInTerminal() {}
}

@MainActor private struct UpdateUIFixture {
    let root: URL
    let suite = "zeus-up1-\(UUID())"
    let defaults: UserDefaults
    let settings: AppSettings
    let controller = UpdateUIController()
    let cards: CardStore
    let managed: ManagedAssistantModel
    let updates: ManagedAgentUpdateModel
    init(unrestricted: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-up1-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        var config = AppSettings.newManagedSession(); config.folder = root.path
        if unrestricted { config.permissionModeID = "full" }
        settings.managedSession = config; settings.managedLaunchedConfig = config
        controller.managedAppliedConfiguration = config
        let controller = controller
        managed = ManagedAssistantModel(settings: settings, controller: { controller })
        managed.refreshAvailability()
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        updates = ManagedAgentUpdateModel(managed: managed, cards: cards)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func pending() { controller.managedAgentUpdatePending = true; updates.reconcile() }
}

@MainActor struct ManagedAgentUpdateModelTests {
    @Test func quietOncePerEdgeAndConversationAndNoRepostAfterClear() throws {
        let f = try UpdateUIFixture(); defer { f.cleanup() }
        f.pending(); f.updates.reconcile(); f.updates.reconcile()
        #expect(f.cards.notices.count == 1 && f.cards.unseenCount == 0)
        #expect(f.cards.cards.isEmpty && f.controller.requests == 0)
        #expect(f.cards.notices.first?.summary == "Claude Code has an update")
        let first = try #require(f.cards.notices.first)
        #expect(f.cards.hasNoticeAction(id: first.id))
        f.cards.clearConversation(); f.updates.reconcile()
        #expect(f.cards.notices.isEmpty, "Clearing history must not repost the notice")
        f.controller.managedAgentUpdatePending = false; f.updates.reconcile(); f.pending()
        #expect(f.cards.notices.count == 1)
        f.controller.managedAgentUpdateConversationID = "next-conversation"; f.updates.reconcile()
        #expect(f.cards.notices.count == 2)
    }
    @Test func pendingQuestionsSuppressNoticeAndExistingLineUntilAnswered() throws {
        let f = try UpdateUIFixture(); defer { f.cleanup() }
        let now = Date()
        f.cards.add(.init(id: "q_up1", kind: .question, body: "Choose", createdAt: now, updatedAt: now))
        f.pending()
        #expect(f.cards.notices.isEmpty)
        f.cards.update(id: "q_up1") { $0.status = .answered }; f.updates.reconcile()
        let id = try #require(f.cards.notices.first?.id)
        f.cards.add(.init(id: "q_up2", kind: .question, body: "Choose again", createdAt: now, updatedAt: now))
        f.updates.reconcile()
        let thread = ConversationModel(cards: f.cards, messaging: AgentMessagingHub())
        #expect(!thread.thread.contains(where: { $0.isNotice }))
        #expect(!f.cards.hasNoticeAction(id: id))
        f.cards.update(id: "q_up2") { $0.status = .answered }; f.updates.reconcile()
        #expect(thread.thread.filter(\.isNotice).count == 1 && f.cards.hasNoticeAction(id: id))
    }
    @Test func clickQueuesSafeResumeWithBusyCaptionAndNoUnsafeLifecycleCall() throws {
        let f = try UpdateUIFixture(); defer { f.cleanup() }
        f.controller.managedStatus = .running(.working); f.pending()
        let id = try #require(f.cards.notices.first?.id)
        f.cards.performNoticeAction(id: id); f.updates.reconcile()
        #expect(f.controller.requests == 1 && f.controller.unsafeRestarts == 0)
        #expect(f.controller.managedSettingsApplication?.kind == .agentUpdate)
        #expect(f.cards.notices.first?.summary == "Restarting when Claude Code is idle…")
        #expect(!f.cards.hasNoticeAction(id: id))
        f.cards.performNoticeAction(id: id)
        #expect(f.controller.requests == 1)
    }
    @Test func unrestrictedLaterDoesNotRepostAndSettingsCanOfferAgain() throws {
        let f = try UpdateUIFixture(unrestricted: true); defer { f.cleanup() }
        f.pending(); let id = try #require(f.cards.notices.first?.id)
        var presented = 0; f.updates.onConfirmation = { presented += 1 }
        f.cards.performNoticeAction(id: id)
        #expect(presented == 1 && f.managed.confirmation != nil && f.controller.requests == 0)
        f.managed.cancelConfirmation(); f.updates.reconcile(); f.updates.reconcile()
        #expect(f.cards.notices.count == 1 && f.cards.notices.first?.resolvedTitle == "Later")
        #expect(!f.cards.hasNoticeAction(id: id))
        f.managed.requestAgentUpdateRestart(); f.managed.confirm(); f.updates.reconcile()
        #expect(f.controller.requests == 1 && f.controller.unsafeRestarts == 0)
    }
    @Test func confirmationCannotAuthorizeAReplacementConversation() throws {
        let f = try UpdateUIFixture(unrestricted: true); defer { f.cleanup() }
        f.pending(); f.managed.requestAgentUpdateRestart()
        f.controller.managedAgentUpdateConversationID = "other-conversation"
        f.managed.confirm()
        #expect(f.controller.requests == 0)
    }
    @Test func durableNoticeRebindsAfterRelaunchInsteadOfDuplicating() throws {
        let f = try UpdateUIFixture(); defer { f.cleanup() }
        f.pending()
        let restored = CardStore(fileURL: f.root.appendingPathComponent("cards.json"))
        #expect(restored.notices.count == 1 && !restored.hasNoticeAction(id: restored.notices[0].id))
        let updates = ManagedAgentUpdateModel(managed: f.managed, cards: restored)
        updates.reconcile()
        #expect(restored.notices.count == 1 && restored.hasNoticeAction(id: restored.notices[0].id))
        f.controller.managedAgentUpdatePending = false; updates.reconcile()
        f.controller.managedAgentUpdatePending = true; updates.reconcile()
        #expect(restored.notices.count == 2)
    }
    @Test func settingsAndNoticeRenderWithAccessibleRestartAction() async throws {
        let f = try UpdateUIFixture(); defer { f.cleanup() }
        f.pending()
        let messaging = AgentMessagingHub()
        let host = NSHostingView(rootView: AssistantSettingsView(settings: f.settings, managed: f.managed, messaging: messaging,
            testMessage: ComposeModel(cards: f.cards, messaging: messaging)).padding(16).frame(width: 560).environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system))
        let window = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 560, height: 1800), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let labels = updateAXLabels(host)
        #expect(labels.contains("Restart assistant to use the update"))
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 1800)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        #expect(image.pixelsWide >= 560 && image.pixelsHigh >= 1800)
        if let destination = ProcessInfo.processInfo.environment["ZEUS_UP1_RENDER"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_ZEUS_UP1_RENDER"] {
            try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: destination))
        }
    }
}

@MainActor private func updateAXLabels(_ root: NSObject) -> [String] {
    var seen: Set<ObjectIdentifier> = []
    func visit(_ node: NSObject) -> [String] {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let label = NSSelectorFromString("accessibilityLabel")
        let children = NSSelectorFromString("accessibilityChildren")
        var result: [String] = []
        if node.responds(to: label), let value = node.perform(label)?.takeUnretainedValue() as? String { result.append(value) }
        if node.responds(to: children), let nodes = node.perform(children)?.takeUnretainedValue() as? [NSObject] { result += nodes.flatMap(visit) }
        return result
    }
    return visit(root)
}
