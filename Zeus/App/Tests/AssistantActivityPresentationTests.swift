import AppKit
import SwiftUI
import Foundation
import Observation
import Synchronization
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

@MainActor @Observable private final class ActivityMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var assistantActivity: AssistantActivity?
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}

@MainActor struct AssistantActivityPresentationTests {
    @Test func managedBlockSuppressesItsActivityUntilItClearsWithoutHidingOtherAgents() {
        for phase in [AssistantActivity.Phase.sent, .thinking, .working] {
            let value = activity(phase)
            #expect(ConversationActivityPresentation.make(value, panelVisible: true, managedStatus: .blocked(reason: "Permission"), managedSessionKey: value.sessionKey) == nil)
            #expect(ConversationActivityPresentation.make(value, panelVisible: true, managedStatus: .blocked(reason: "Permission")) == nil)
            #expect(ConversationActivityPresentation.make(value, panelVisible: true, managedStatus: .blocked(reason: "Permission"), managedSessionKey: "codex:other")?.phase == phase)
            #expect(ConversationActivityPresentation.make(value, panelVisible: true, managedStatus: .running(.working), managedSessionKey: value.sessionKey)?.phase == phase)
        }
    }

    @Test func workingSeamHasNoUIStaleTimeoutOrFiniteProgressRequirement() throws {
        let old = activity(.working, progress: nil) // since .distantPast; runtime owns the deadline.
        let row = try #require(ConversationActivityPresentation.make(old, panelVisible: true, managedStatus: .running(.working), managedSessionKey: old.sessionKey))
        #expect(row.typingPhase == .working && row.progress == nil)
    }
    private func activity(_ phase: AssistantActivity.Phase, progress: Double? = nil) -> AssistantActivity {
        .init(phase: phase, sessionKey: "claude:test", agentName: "Claude", detail: phase == .working ? "Drafting" : nil, progress: progress, since: .distantPast)
    }

    @Test func activityRowExistsOnlyForLiveActivityInAnOpenPanel() {
        for phase in [AssistantActivity.Phase.sent, .thinking, .working] {
            let value = activity(phase)
            #expect(ConversationActivityPresentation.make(value, panelVisible: false) == nil)
            #expect(ConversationActivityPresentation.make(value, panelVisible: true)?.phase == phase)
        }
        #expect(ConversationActivityPresentation.make(nil, panelVisible: true) == nil)
        #expect(ConversationActivityPresentation.make(nil, panelVisible: false) == nil)
    }

    @Test func activityPhasesMapDirectlyOntoDesignerVariants() throws {
        for (phase, expected) in [(AssistantActivity.Phase.sent, ZeusTypingIndicator.Phase.sent), (.thinking, .thinking), (.working, .working)] {
            let row = try #require(ConversationActivityPresentation.make(activity(phase), panelVisible: true))
            #expect(row.typingPhase == expected)
        }
    }

    @Test func designerProgressHeightFeedsFollowingWithoutPassingTheMessageTop() throws {
        func height(progress: Double?) throws -> CGFloat {
            let presentation = try #require(ConversationActivityPresentation.make(activity(.working, progress: progress), panelVisible: true))
            let host = TestHostingView(rootView: ConversationActivityRow(presentation: presentation)
                .environment(\.zeusAnimationsActive, false).environment(\.zeusFontChoice, .system).frame(width: 340))
            return host.fittingSize.height
        }
        let plain = try height(progress: nil), progress = try height(progress: 0.4)
        #expect(progress > plain)
        let short = [plain, progress].map { rowHeight in
            ConversationAutoScroll.targetOffset(viewport: .init(offset: 0, contentHeight: 800 + 200 + 10 + rowHeight, height: 300), newestMessageTop: 800, pinned: true)
        }
        #expect(short[1] > short[0])
        for rowHeight in [plain, progress] {
            let viewport = ConversationViewport(offset: 800, contentHeight: 800 + 2000 + 10 + rowHeight, height: 300)
            #expect(ConversationAutoScroll.targetOffset(viewport: viewport, newestMessageTop: 800, pinned: true) == 800)
            #expect(ConversationAutoScroll.targetOffset(viewport: viewport, newestMessageTop: 800, pinned: false) == 800)
        }
    }

    @Test func activityRowUsesPhaseDetailAndSafeProgress() throws {
        #expect(ConversationActivityPresentation.make(activity(.sent), panelVisible: true)?.label == "Sent to Claude…")
        #expect(ConversationActivityPresentation.make(activity(.thinking), panelVisible: true)?.label == "Claude is thinking…")
        let working = try #require(ConversationActivityPresentation.make(activity(.working, progress: 1.5), panelVisible: true))
        #expect(working.label == "Drafting")
        #expect(working.progress == 1)
        #expect(ConversationActivityPresentation.make(activity(.working, progress: -.infinity), panelVisible: true)?.progress == nil)
    }

    @Test func hubForwardsObservableActivityAndPreviewCanReplaceOrHideIt() throws {
        let runtime = ActivityMessaging()
        let hub = AgentMessagingHub(); hub.runtime = runtime
        #expect(hub.assistantActivity == nil)
        let changes = Mutex(0)
        withObservationTracking { _ = hub.assistantActivity } onChange: { changes.withLock { $0 += 1 } }
        runtime.assistantActivity = activity(.thinking)
        #expect(changes.withLock { $0 } == 1)
        #expect(hub.assistantActivity == runtime.assistantActivity)
        hub.previewEnabled = true
        #expect(hub.assistantActivity == nil)
        hub.previewActivity = .working
        hub.previewActivityDetail = "Preview task"
        hub.previewActivityProgress = 0.4
        let value = try #require(hub.assistantActivity)
        #expect(value.phase == .working && value.detail == "Preview task" && value.progress == 0.4)
        #expect(hub.assistantActivity?.since == value.since)
        hub.discardPendingDeliveries()
        #expect(hub.assistantActivity == nil)
        hub.previewEnabled = false
        #expect(hub.assistantActivity == runtime.assistantActivity)
    }

    @Test func onlyDeliveredPreviewMessagesStartActivity() async {
        let hub = AgentMessagingHub(); hub.previewEnabled = true
        for outcome in [AgentMessagingHub.PreviewOutcome.failed, .queued] {
            hub.previewOutcome = outcome
            _ = await hub.sendUserMessage("Hello")
            #expect(hub.assistantActivity == nil)
        }
        hub.previewOutcome = .delivered
        _ = await hub.sendUserMessage("Hello")
        #expect(hub.assistantActivity?.phase == .sent)
    }

    @Test func ruleThreeBRespectsTransientOverrideUnseenQuestionAndQuietPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-activity-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let messaging = ActivityMessaging()
        let status = AvatarStatusModel(cards: cards, clock: { clock.now }, quietHours: { _ in true }, assistantActivity: { messaging.assistantActivity })
        #expect(status.state == .sleeping)
        let question = Card(kind: .question, body: "Question")
        cards.add(question); cards.markSeen(id: question.id)
        #expect(status.state == .waiting)
        messaging.assistantActivity = activity(.sent)
        #expect(status.state == .thinking)
        messaging.assistantActivity = activity(.thinking)
        #expect(status.state == .thinking)
        messaging.assistantActivity = activity(.working, progress: 0.4)
        #expect(status.presentation == AvatarPresentation(state: .working, detail: "Drafting", progress: 0.4))
        status.setOverride(.happy, detail: "Override", progress: nil, ttl: 10)
        #expect(status.state == .happy)
        let card = Card(kind: .message, body: "New", mood: .talking)
        cards.add(card); status.noteNewCard(card)
        #expect(status.state == .talking)
        clock.advance(2.5); status.tick()
        #expect(status.state == .happy)
        clock.advance(7.5); status.tick()
        #expect(status.state == .alert)
        cards.markSeen(id: card.id)
        #expect(status.state == .working)
        messaging.assistantActivity = nil
        #expect(status.state == .waiting)
        cards.setConversationOpen(true)
        #expect(status.state == .waiting) // Reading doesn't close an open question (TB1).
        #expect(cards.skip(id: question.id))
        #expect(status.state == .sleeping)
    }

    @Test func avatarObservesActivityTransitionsWithoutPollingOrOpeningAPanel() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-activity-observation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let messaging = ActivityMessaging()
        let status = AvatarStatusModel(cards: cards, assistantActivity: { messaging.assistantActivity })
        let changes = Mutex(0)
        withObservationTracking { _ = status.presentation } onChange: { changes.withLock { $0 += 1 } }
        messaging.assistantActivity = activity(.sent)
        #expect(changes.withLock { $0 } == 1)
        #expect(status.state == .thinking)
        messaging.assistantActivity = nil
        #expect(status.state == .idle)
        #expect(status.nextDeadline == nil)
    }

    @Test func shellUsesTheHubForRuleThreeBAndANewPreviewCardEndsThePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-shell-activity-\(UUID())")
        let name = "zeus-shell-activity-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "avatar.manuallyHidden")
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let shell = ShellController(defaults: defaults, cards: cards, settings: AppSettings(defaults: defaults, userDirectory: nil))
        shell.messaging.previewEnabled = true; shell.messaging.previewActivity = .thinking
        #expect(shell.status.state == .thinking)
        shell.injectDemo(.message)
        #expect(shell.messaging.assistantActivity == nil)
        #expect(shell.status.state == .talking)
    }
}
