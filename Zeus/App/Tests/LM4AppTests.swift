import AppKit
import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Observable final class LM4Controller: LearningDeliveryPresenting, ManagedSessionControlling, ManagedSettingsApplying, ManagedAgentUpdating {
    var pendingLearningDeliveries: [PendingLearningDelivery] = []
    var discardedLearningDeliveries: [DiscardedLearningDelivery] = []
    var deliveryHolds: [DeliveryHold] = []
    var managedSetupStale = ManagedSetupStaleness()
    var managedTemplateReplacement: ManagedTemplateReplacement?
    var cancellations: [String] = []
    var replacements: [ManagedTemplateReplacement] = []
    var restarts = 0
    var unsafeRestarts = 0
    var replacementFails = false
    func requestLearningDeliveryCancellation(deliveryID: String) { cancellations.append(deliveryID) }
    func restartManagedAssistantForSetup() {
        restarts += 1
        if let config = managedAppliedConfiguration { managedSettingsApplication = .init(id: UUID(), configuration: config, kind: .agentUpdate) }
    }
    func replaceEditedManagedTemplates(_ snapshot: ManagedTemplateReplacement) throws {
        if replacementFails { throw CocoaError(.fileWriteNoPermission) }
        replacements.append(snapshot); managedSetupStale.templateEdited = false
    }
    var managedStatus: ManagedSessionStatus = .running(.idle)
    var managedTmuxSessionName: String? = "private-fixture"
    var managedAttachCommand: String? = "private-fixture attach"
    var managedAppliedConfiguration: ManagedSessionConfig?
    var managedSettingsApplication: ManagedSettingsApplication?
    var managedSettingsApplicationError: String?
    var managedCanResumeSettings = true
    var managedAgentUpdatePending = false
    var managedAgentUpdateLastRestartID: UUID?
    var managedAgentUpdateConversationID: String? = "conversation"
    func restartManagedAgentForUpdate() { unsafeRestarts += 1 }
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

@MainActor final class LM4Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-lm4-\(UUID())")
    let suite = "zeus-lm4-\(UUID())"
    let defaults: UserDefaults
    let controller = LM4Controller()
    let cards: CardStore
    let settings: AppSettings
    let managed: ManagedAssistantModel
    let deliveries: LearningDeliveryModel
    var now = Date(timeIntervalSince1970: 1_792_090_800)
    init(unrestricted: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        var config = AppSettings.newManagedSession(); config.folder = root.path; config.permissionModeID = unrestricted ? "full" : "ask"
        settings.managedSession = config; settings.managedLaunchedConfig = config
        controller.managedAppliedConfiguration = config
        let controller = controller
        managed = ManagedAssistantModel(settings: settings, controller: { controller })
        managed.refreshAvailability()
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let cards = cards
        managed.hasPendingQuestion = { cards.hasOpenQuestion }
        // Fixtures reconcile explicitly; no wall-clock sleeps decide boundary assertions.
        let clock = LM4Clock(now: now)
        deliveries = LearningDeliveryModel(cards: cards, source: { controller }, clock: { clock.now })
        self.clock = clock
        deliveries.conversationID = { controller.managedAgentUpdateConversationID }
        deliveries.agentName = { "Claude" }
        deliveries.restartAssistant = { [weak managed] in managed?.requestSetupRestart() }
        deliveries.setupError = { [weak managed] in managed?.agentUpdateRestartError }
        deliveries.setupProgress = { [weak managed] in
            guard let managed, managed.setupNeedsRestart, managed.agentUpdateRestartPending else { return nil }
            return managed.agentUpdateWaitingText
        }
    }
    let clock: LM4Clock
    func cleanup() { deliveries.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func hold(_ reason: DeliveryHold.Reason, id: String = "delivery", age: TimeInterval = 600, kind: Delivery.Kind = .reflection) {
        controller.deliveryHolds = [.init(deliveryID: id, kind: kind, since: clock.now.addingTimeInterval(-age), reason: reason)]
        deliveries.reconcile()
    }
    func pending(id: String = "delivery") {
        controller.pendingLearningDeliveries = [.init(id: id, kind: .reflection, text: "Exact prepared text\nSecond line.", preparedAt: clock.now, sessionLabel: "Unreceived target")]
        deliveries.reconcile()
    }
}
@MainActor final class LM4Clock { var now: Date; init(now: Date) { self.now = now } }

@MainActor struct LM4AppTests {
    @Test func receiptUpdatesReadyNoticeInPlaceAndKeepsExactTextAcrossRelaunch() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        for kind in [Learning.Kind.digest, .moment] {
            let learning = Learning(id: kind.rawValue, kind: kind, createdAt: f.now, text: "Back at the Mac\nexact ‹name› body")
            let ready = LearningDeliveryModel.preparedNotice(learning)
            #expect(f.cards.recordNotice(ready))
            #expect(!ready.summary.hasPrefix("Sent"))
            #expect(ready.detail == learning.text && ready.actionTitle == "View")
            let sent = ThreadNotice.learning(learning)
            #expect(f.cards.recordLearningNotice(.init(id: sent.id, kind: .reflection, createdAt: f.now.addingTimeInterval(60), summary: sent.summary, actionTitle: "View", detail: learning.text, ruleID: nil), action: nil))
            let stored = try #require(f.cards.notices.first { $0.id == ready.id })
            #expect(stored.createdAt == f.now && stored.summary == sent.summary && stored.detail == learning.text)
            #expect(f.cards.notices.filter { $0.id == ready.id }.count == 1)
        }
        #expect(f.cards.unseenCount == 0 && f.cards.cards.isEmpty)
        #expect(CardStore(fileURL: f.root.appendingPathComponent("cards.json")).notices == f.cards.notices)
    }
    @Test func persistedFalseSentBecomesReadyButAnActualReceiptAlwaysWins() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        let old = ThreadNotice(id: "n_delivery", kind: .learning, createdAt: f.now.addingTimeInterval(-500), summary: "Sent a daily reflection", actionTitle: "View", detail: "Exact prepared text\nSecond line.")
        #expect(f.cards.recordNotice(old)); f.pending()
        #expect(f.cards.notices.first?.summary == "Evening reflection ready for your assistant" && f.cards.notices.first?.createdAt == old.createdAt)
        #expect(f.cards.updateNotice(id: old.id) { $0.summary = "Sent a daily reflection" })
        f.deliveries.receivedDeliveryIDs = { ["delivery"] }; f.deliveries.reconcile()
        #expect(f.deliveries.pending.isEmpty && f.cards.notices.first?.summary == "Sent a daily reflection")
        f.deliveries.receivedDeliveryIDs = { nil }; f.deliveries.reconcile()
        #expect(f.cards.notices.first?.summary == "Sent a daily reflection", "Storage unavailability cannot disprove an earlier receipt")
    }
    @Test func vanishedPendingItemNeverSynthesizesAReceipt() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.pending()
        let journal = LM2JournalFake(), viewer = JournalViewerModel(journal: LM2JournalFake(), now: f.now)
        viewer.deliveries = f.deliveries; viewer.sentOnly = true
        #expect(viewer.waiting.count == 1 && viewer.items.isEmpty)
        f.controller.pendingLearningDeliveries = []; f.deliveries.reconcile()
        #expect(viewer.waiting.isEmpty && viewer.items.isEmpty && journal.records.isEmpty && f.cards.notices.allSatisfy { !$0.summary.hasPrefix("Sent") })
    }
    @Test func tenMinuteBoundaryReasonChangesAndClearingAreQuietAndInPlace() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.hold(.busy, age: 599)
        #expect(f.cards.notices.isEmpty && f.deliveries.menuStatus == nil)
        f.clock.now += 1; f.deliveries.reconcile()
        let initial = try #require(f.cards.notices.first)
        #expect(initial.summary.contains("busy for 10 min") && f.deliveries.menuStatus == "Waiting to deliver to Claude")
        f.clock.now += 55 * 60; f.deliveries.reconcile()
        #expect(f.cards.notices.count == 1 && f.cards.notices.first?.summary.contains("1 h 5 min") == true)
        #expect(f.cards.notices.first?.createdAt == initial.createdAt)
        f.hold(.draft)
        #expect(f.cards.notices.count == 1 && f.cards.notices.first?.secondaryTitle == "Don't send")
        #expect(f.deliveries.menuStatus == "Waiting on unsent text in Terminal")
        f.cards.performSecondaryNoticeAction(id: initial.id)
        #expect(f.controller.cancellations == ["delivery"])
        #expect(f.controller.deliveryHolds.count == 1, "A request is not permission to cancel or erase native text")
        f.controller.deliveryHolds = []; f.deliveries.reconcile()
        #expect(f.cards.notices.isEmpty && f.deliveries.menuStatus == nil && f.cards.unseenCount == 0)
    }
    @Test func separateHoldsDoNotDuplicateUserDraftCardsAndOldActionsAreSafe() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.hold(.draft, kind: .userMessage)
        #expect(f.cards.notices.isEmpty)
        f.hold(.olderSetup); #expect(f.cards.notices.isEmpty)
        f.hold(.busy)
        var opened = 0; f.deliveries.openTerminal = { opened += 1 }
        let id = try #require(f.cards.notices.first?.id)
        f.controller.deliveryHolds = [] // state changed before the observer has reconciled
        f.cards.performNoticeAction(id: id); #expect(opened == 0)
    }
    @Test func waitingIsOutsideDayFilterAndOffEmptyCopyDoesNotHideOlderReceipts() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        let journal = LM2JournalFake(), viewer = JournalViewerModel(journal: LM2JournalFake(), now: f.now)
        viewer.deliveries = f.deliveries; viewer.sentOnly = true
        viewer.learningEnabled = { false }
        #expect(viewer.emptyCaption.contains("Learn from me is off"))
        viewer.learningEnabled = { true }; #expect(viewer.emptyCaption.contains("morning summary"))
        f.pending(); viewer.day = f.now.addingTimeInterval(-86400)
        #expect(viewer.waiting.count == 1 && viewer.waiting[0].text.contains("\n"))
        viewer.search = "missing"; #expect(viewer.waiting.isEmpty && viewer.emptyCaption == "Nothing matches.")
        viewer.search = "Second line"; #expect(viewer.waiting.count == 1)
        try journal.append(.init(time: f.now, level: .activity, kind: .sentToAssistant, payload: .init(.init(description: "Summary", text: "Received"))))
        let oldDay = JournalViewerModel(journal: journal, now: f.now.addingTimeInterval(-86400)); oldDay.sentOnly = true; oldDay.learningEnabled = { false }
        #expect(oldDay.emptyCaption == "Nothing received on this day.")
    }
    @Test func setupVariantsPendingQuestionsNonceAndRestartProgress() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.controller.managedSetupStale.tools = true; f.deliveries.reconcile()
        let original = try #require(f.cards.notices.first)
        #expect(original.summary == "Zeus has new tools for your assistant")
        f.controller.managedSetupStale.template = true; f.deliveries.reconcile()
        #expect(f.cards.notices.first?.summary.contains("tools and instructions") == true)
        f.cards.add(.init(id: "question", kind: .question, body: "Choose", createdAt: f.now, updatedAt: f.now)); f.deliveries.reconcile()
        #expect(f.cards.notices.isEmpty && !f.managed.setupCanRestart)
        f.cards.update(id: "question") { $0.status = .answered }; f.clock.now += 60; f.deliveries.reconcile()
        #expect(f.cards.notices.first?.id == original.id && f.cards.notices.first?.createdAt == original.createdAt)
        f.cards.performNoticeAction(id: original.id); f.deliveries.reconcile()
        #expect(f.controller.restarts == 1 && f.controller.unsafeRestarts == 0)
        #expect(f.cards.notices.first?.summary == f.managed.agentUpdateWaitingText)
        #expect(!f.cards.hasNoticeAction(id: original.id))
        f.controller.managedSettingsApplication = nil; f.controller.managedSetupStale = .init(); f.deliveries.reconcile()
        #expect(f.cards.notices.isEmpty)
        f.controller.managedAgentUpdateConversationID = "next"; f.controller.managedSetupStale.template = true; f.deliveries.reconcile()
        #expect(f.cards.notices.first?.id != original.id && f.cards.notices.count == 1)
    }
    @Test func failedSafeRestartShowsErrorAndKeepsRetryOnTheSameNotice() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.controller.managedSetupStale.tools = true; f.deliveries.reconcile()
        let id = try #require(f.cards.notices.first?.id)
        f.managed.requestSetupRestart(); f.deliveries.reconcile()
        f.controller.managedSettingsApplicationError = "Native conversation could not resume"
        f.controller.managedSettingsApplication = nil; f.deliveries.reconcile()
        #expect(f.cards.notices.count == 1 && f.cards.notices.first?.id == id)
        #expect(f.cards.notices.first?.summary == "Couldn't restart Claude. Native conversation could not resume.")
        #expect(f.cards.hasNoticeAction(id: id) && f.managed.note == f.controller.managedSettingsApplicationError)
    }
    @Test func unrestrictedSetupRestartRequiresSameConversationAndAppliedConfiguration() throws {
        let f = try LM4Fixture(unrestricted: true); defer { f.cleanup() }
        f.controller.managedSetupStale.tools = true
        f.managed.requestSetupRestart(); #expect(f.controller.restarts == 0)
        guard case .restartForSetup = f.managed.confirmation else { Issue.record("Missing unrestricted confirmation"); return }
        f.controller.managedAgentUpdateConversationID = "different"; f.managed.confirm()
        #expect(f.controller.restarts == 0)
        f.managed.requestSetupRestart(); f.managed.confirm()
        #expect(f.controller.restarts == 1 && f.controller.unsafeRestarts == 0)
    }
    @Test func templateReplacementIsExplicitSnapshotScopedAndFailureHonest() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.controller.managedSetupStale = .init(template: true, templateEdited: true)
        let snapshot = ManagedTemplateReplacement(folder: f.root.path, hashes: ["AGENTS.md": "old", "CLAUDE.md": "old"])
        f.controller.managedTemplateReplacement = snapshot
        f.managed.requestTemplateReplacement(); #expect(f.managed.templateReplacement == snapshot && f.controller.replacements.isEmpty)
        f.managed.templateReplacement = nil; f.managed.confirmTemplateReplacement(); #expect(f.controller.replacements.isEmpty)
        f.managed.requestTemplateReplacement()
        f.controller.managedTemplateReplacement = .init(folder: f.root.path, hashes: ["AGENTS.md": "changed"])
        f.managed.confirmTemplateReplacement(); #expect(f.controller.replacements.isEmpty && f.managed.actionError != nil)
        f.controller.managedTemplateReplacement = snapshot; f.managed.requestTemplateReplacement(); f.controller.replacementFails = true
        f.managed.confirmTemplateReplacement(); #expect(f.controller.replacements.isEmpty && f.controller.restarts == 0 && f.managed.actionError != nil)
        f.controller.replacementFails = false; f.managed.requestTemplateReplacement(); f.managed.confirmTemplateReplacement()
        #expect(f.controller.replacements == [snapshot] && f.controller.restarts == 1)
    }
    @Test func currentCustomizedTemplatesAreNotClaimedObsolete() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.controller.managedSetupStale.templateEdited = true
        f.deliveries.reconcile()
        #expect(f.cards.notices.isEmpty && f.managed.setupNote == nil)
        f.managed.requestTemplateReplacement(); #expect(f.managed.templateReplacement == nil)
    }
    @Test func transientNoticeRemovalIsTransactional() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.hold(.draft)
        let saved = f.cards.notices
        let file = f.root.appendingPathComponent("cards.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        f.controller.deliveryHolds = []; f.deliveries.reconcile()
        #expect(f.cards.notices == saved && f.cards.persistenceError != nil)
        try FileManager.default.removeItem(at: file); f.deliveries.reconcile()
        #expect(f.cards.notices.isEmpty)
    }
    @Test func observableRuntimeSnapshotsUpdateWithoutAViewerOrPolling() async throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.deliveries.start(); f.deliveries.start()
        f.controller.pendingLearningDeliveries = [.init(id: "observed", kind: .learning, text: "Exact", preparedAt: f.now, sessionLabel: "", learningKind: .moment)]
        for _ in 0..<100 where f.deliveries.pending.isEmpty { await Task.yield() }
        #expect(f.deliveries.pending.first?.id == "observed")
        #expect(f.cards.notices.first?.summary == "Note ready for your assistant")
        f.deliveries.stop(); f.controller.pendingLearningDeliveries = []
        for _ in 0..<5 { await Task.yield() }
        #expect(f.deliveries.pending.count == 1, "Stopped observations must not restart themselves")
    }
    @Test func singleDeliveryCancellationKeepsNativeTextAndDefaultsToKeep() {
        let alert = ShellController.makeDraftCancellationAlert(count: 1)
        #expect(alert.messageText == "Cancel this queued message?")
        #expect(alert.informativeText.contains("Terminal will stay there"))
        #expect(alert.buttons.first?.title == "Keep Message" && alert.buttons.first?.keyEquivalent == "\r")
    }
}
