import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

// Q3 findings become regression assertions as their fixes land.
// Deferred/cross-owner audit cases still record the outstanding behavior explicitly.
@MainActor @Observable private final class Q3Messaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var deliveryIssue: DeliveryIssue?
    var outcome = MessageSendResult.delivered
    var calls: [String] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { calls.append(text); return outcome }
}

@MainActor private final class Q3Fixture {
    let root: URL
    let suite = "zeus-q3-\(UUID())"
    let defaults: UserDefaults
    let clock = TestClock()
    let settings: AppSettings
    let cards: CardStore
    let messaging = Q3Messaging()
    let model: ConversationModel
    var cardURL: URL { root.appendingPathComponent("cards.json") }

    init() throws {
        var worktree = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { worktree.deleteLastPathComponent() }
        root = worktree.appendingPathComponent("build/q3-fixtures/\(UUID())")
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        let clock = clock
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        model = ConversationModel(cards: cards, messaging: messaging, clock: { clock.now })
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

@MainActor struct Q3AuditEvidenceTests {
    @Test func freshInstallCreatesOneWelcomeAndHasNoConnectedAssistant() throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        #expect(f.cards.cards.isEmpty && f.messaging.sessions.isEmpty && f.settings.assistantSessionKey == nil)
        #expect(!f.settings.hasShownWelcome && !f.settings.quietHoursEnabled && !f.settings.soundEnabled)
        #expect(f.settings.backend == .claude && f.settings.deliveryMethod == .channel && f.settings.fontChoice == .pixel)
        #expect(WelcomeCard.installIfNeeded(cards: f.cards, settings: f.settings, now: f.clock.now))
        #expect(f.cards.card(id: WelcomeCard.id)?.body.contains("zeus://settings/agent") == false)
        #expect(f.cards.unseenCount == 1)
        let restored = CardStore(fileURL: f.cardURL)
        let settings = AppSettings(defaults: f.defaults, userDirectory: nil)
        #expect(!WelcomeCard.installIfNeeded(cards: restored, settings: settings))
        #expect(restored.cards.count == 1 && settings.hasShownWelcome)
    }

    @Test func outgoingHistoryFailurePreservesDraftAndNeverCallsRuntime() async throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        let historyURL = f.root.appendingPathComponent("history/cards.json")
        let cards = CardStore(fileURL: historyURL)
        cards.add(Card(kind: .message, body: "Existing durable history"))
        let original = try Data(contentsOf: historyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: historyURL.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: historyURL.deletingLastPathComponent().path) }
        let status = AvatarStatusModel(cards: cards)
        let socket = "/private/tmp/q3_\(UUID().uuidString.prefix(8)).sock"
        let ledgerURL = f.root.appendingPathComponent("deliveries.json")
        let runtime = ZeusRuntime(cards: cards, status: status, characters: f.settings, routing: f.settings,
            socketPath: socket, ledgerURL: ledgerURL, connectors: [])
        try runtime.start(); defer { runtime.stop(); try? FileManager.default.removeItem(atPath: socket) }
        let model = ConversationModel(cards: cards, messaging: runtime)
        model.draft = "Keep this in my conversation"
        let result = try #require(await model.send())
        guard case .rejected = result else { Issue.record("Expected durable history rejection"); return }
        #expect(cards.persistenceError != nil && model.draft == "Keep this in my conversation")
        #expect(model.thread.count == 1)
        #expect(runtime.ledger?.records.isEmpty == true)
        #expect(try Data(contentsOf: historyURL) == original)
        #expect(CardStore(fileURL: historyURL).cards.count == 1)
        let compose = ComposeModel(cards: cards, messaging: runtime)
        compose.draft = "Settings test message"
        await compose.send()
        #expect(compose.draft == "Settings test message")
        guard case .failed? = compose.result else { Issue.record("Expected Settings persistence failure"); return }
        #expect(runtime.ledger?.records.isEmpty == true)

    }

    @Test func failedAndQueuedBubbleOutcomesSurviveReloadAndFailedCanRetry() async throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        for outcome in [MessageSendResult.failed(reason: "Could not save delivery"), .queued(reason: "Assistant offline")] {
            f.messaging.outcome = outcome
            f.model.draft = "Outcome \(f.messaging.calls.count)"
            _ = await f.model.send()
            f.clock.advance(1)
        }
        #expect(f.model.thread.count == 2)
        #expect(f.model.thread.allSatisfy { $0.outcome != nil })
        let restored = ConversationModel(cards: CardStore(fileURL: f.cardURL), messaging: f.messaging)
        #expect(restored.thread.count == 2 && restored.thread.map(\.outcome) == f.model.thread.map(\.outcome))
        let calls = f.messaging.calls.count
        await restored.retry(entryID: restored.thread[0].id)
        #expect(f.messaging.calls.count == calls + 1)
        #expect(restored.thread.count == 2)
    }

    @Test func queuedBubbleDoesNotChangeWhenRuntimeLaterReportsRecovery() async throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        let runtime = ZeusRuntime(cards: f.cards, status: AvatarStatusModel(cards: f.cards), characters: f.settings,
            routing: f.settings, socketPath: "/private/tmp/q3_\(UUID().uuidString.prefix(8)).sock",
            ledgerURL: f.root.appendingPathComponent("deliveries.json"), connectors: [])
        try runtime.start(); defer { runtime.stop() }
        let model = ConversationModel(cards: f.cards, messaging: runtime)
        model.draft = "Send when you reconnect"
        _ = await model.send()
        let record = try #require(runtime.ledger?.records.first)
        _ = try runtime.acknowledge(ids: [record.delivery.id], sessionKey: record.delivery.sessionKey)
        #expect(runtime.ledger?.record(id: record.delivery.id)?.delivery.ackedAt != nil)
        guard case .delivery(.queued)? = model.thread.last?.outcome else { Issue.record("Expected stale queued outcome"); return }
        print("Q3 recovery: ledger is acknowledged while the source bubble still says queued")
    }

    @Test func successfulRetryClearsMatchingDraftWithoutCreatingASecondBubble() async throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        f.messaging.outcome = .failed(reason: "No target")
        f.model.draft = "Do this once"
        _ = await f.model.send()
        let entry = try #require(f.model.thread.last)
        #expect(f.model.draft == "Do this once")
        f.messaging.outcome = .delivered
        await f.model.retry(entryID: entry.id)
        #expect(f.model.draft.isEmpty)
        _ = await f.model.send()
        #expect(f.messaging.calls == ["Do this once", "Do this once"])
        #expect(f.model.thread.count == 1)
    }

    @Test func tabUsesNativeTraversalForWelcomeAndAttachmentOnlyContent() throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        f.cards.add(WelcomeCard.make(now: f.clock.now))
        let card = Card(kind: .content, title: "Your draft", body: "Read it",
                        attachments: [Attachment(id: "draft", kind: .file, label: "Draft", target: "/tmp/draft.txt")])
        f.cards.add(card)
        #expect(f.model.shortcutTarget == nil && f.model.newestOpenQuestion == nil)
        let shell = ShellController(defaults: f.defaults, cards: f.cards, settings: f.settings)
        defer { shell.stop() }
        // Create event values without dispatching input or activating a window.
        for backwards in [false, true] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: backwards ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            #expect(!shell.handleConversationKey(event))
            #expect(shell.cardPanelState.keyboardScrollRequest == 0)
        }

    }

    @Test func sameFolderAndHistoricalLabelsStayDistinctWithoutRawIdentityTokens() {
        func session(pid: Int) -> ConnectedSession {
            ConnectedSession(id: UUID(), sessionKey: "claude:/work/ParkHub/Zeus#\(pid).1791826260000000", agent: .claude,
                cwd: "/work/ParkHub/Zeus", clientName: "Claude", supportsChannel: true, tmuxPane: nil, connectedAt: Date())
        }
        let a = session(pid: 7208), b = session(pid: 7210)
        #expect(SessionLabels.label(for: a) != SessionLabels.label(for: b))
        #expect(ConversationLayout.sessionLabel(key: a.sessionKey, sessions: [a, b]) != ConversationLayout.sessionLabel(key: b.sessionKey, sessions: [a, b]))
        #expect(!ConversationLayout.sessionLabel(key: a.sessionKey, sessions: []).contains("7208.1791826260000000"))
    }

    @Test func hiddenAndQuietArrivalsStayUnseenAndNeverReplayAsPeek() throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        let visibility = AvatarVisibilityModel(defaults: f.defaults, clock: { f.clock.now })
        visibility.hide(for: .hour)
        let peek = PeekModel(store: f.cards, clock: { f.clock.now })
        let card = Card(kind: .message, body: "While hidden")
        f.cards.add(card)
        #expect(!peek.receive(card, suppression: .init(hidden: visibility.isHidden), reduceMotion: false, typewriter: true))
        f.clock.advance(3600); visibility.tick()
        #expect(!visibility.isHidden && f.cards.unseenCount == 1)
        #expect(!peek.receive(card, suppression: .init(), reduceMotion: false, typewriter: true))
        let quiet = Card(kind: .message, body: "While quiet")
        f.cards.add(quiet)
        #expect(!peek.receive(quiet, suppression: .init(quiet: true), reduceMotion: false, typewriter: true))
        #expect(f.cards.unseenCount == 2)
        let restored = CardStore(fileURL: f.cardURL)
        #expect(restored.unseenCount == 2)
        f.cards.markSeen(id: card.id); _ = f.cards.markRevealed(id: card.id)
        let reload = CardStore(fileURL: f.cardURL)
        #expect(reload.seenIDs.contains(card.id) && reload.revealedIDs.contains(card.id))
    }

    @Test func noRuntimeFailureExplainsTheBrokenLinkAndRetainsEditableText() async throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        let hub = AgentMessagingHub()
        let model = ConversationModel(cards: f.cards, messaging: hub)
        model.draft = "Can you help?"
        let result = try #require(await model.send())
        let id = try #require(model.thread.last?.sourceCardID)
        #expect(result == .message(cardID: id, outcome: .failed(reason: "Zeus isn't connected to your assistant. Retry, or check Settings → Assistant.")))
        #expect(model.draft == "Can you help?" && CardStore(fileURL: f.cardURL).card(id: id)?.body == model.draft)
    }

    @Test func displayRemovalClampsToRemainingScreenAndDraftAndChipSurvivePanelCloseOpen() throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let old = CGRect(x: -1200, y: 600, width: 192, height: 210)
        let chosen = try #require(PanelPlacement.screen(for: old, in: [screen]))
        #expect(screen.contains(PanelPlacement.clamp(old, to: chosen)))
        let question = Card(kind: .question, body: "Reply?", input: InputSpec())
        f.cards.add(question)
        f.model.openPanel(viewportManaged: true)
        f.model.draft = "Still editing"
        f.model.clearReplyTarget(); f.model.closePanel(); f.model.openPanel(viewportManaged: true)
        #expect(f.model.draft == "Still editing" && f.model.replyTarget == nil)
        let reloaded = ConversationModel(cards: CardStore(fileURL: f.cardURL), messaging: f.messaging)
        #expect(reloaded.draft.isEmpty && reloaded.replyTarget?.id == question.id)
    }

    @Test func nativeWarningSurfaceHasMenuEntryAndSeparateAvatarAccessibilityAction() throws {
        let f = try Q3Fixture(); defer { f.cleanup() }
        let shell = ShellController(defaults: f.defaults, cards: f.cards, settings: f.settings)
        defer { shell.stop() }
        shell.messaging.previewEnabled = true
        shell.messaging.previewDeliveryIssue = DeliveryIssue(title: "Couldn't reach your assistant", detail: "A reply needs retry", pendingCount: 1, since: f.clock.now)
        let menu = shell.makeContextMenu()
        // MB1: the one menu routes "Delivery problem…" through its own target to `shell.perform(.deliveryProblem)`.
        #expect(menu.items.contains { $0.title == "Delivery problem…" && $0.identifier?.rawValue == "delivery" && $0.action != nil && $0.target != nil })
        #expect(shell.menuModel.sections[1].contains { $0.kind == .action(.deliveryProblem) })
        let avatar = AvatarInteractionView(rootView: SpriteAvatarView(settings: f.settings, status: shell.status,
            messaging: shell.messaging, artLayout: shell.artLayout, activity: shell.surfaceActivity))
        #expect(avatar.accessibilityCustomActions()?.map(\.name) == ["Show delivery problem"])
        var warnings = 0, talks = 0
        avatar.onShowDeliveryProblem = { warnings += 1 }; avatar.onClick = { talks += 1 }
        #expect(avatar.accessibilityShowDeliveryProblem())
        #expect(warnings == 1 && talks == 0)
        #expect(avatar.accessibilityPerformPress())
        #expect(warnings == 1 && talks == 1)
        #expect(avatar.accessibilityLabel()?.contains("A reply needs retry") == true)
        shell.messaging.previewDeliveryIssue = nil
        #expect(avatar.accessibilityCustomActions()?.isEmpty == true)
        #expect(!avatar.accessibilityShowDeliveryProblem())
        #expect(!shell.makeContextMenu().items.contains { $0.title == "Delivery problem…" })
    }

    @Test func pm7FileAttachmentWithSpacesPreservesTheActualLocalPath() throws {
        var worktree = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { worktree.deleteLastPathComponent() }
        let path = worktree.appendingPathComponent("Zeus/Resources/AssistantTemplate/AGENTS.md").path
        #expect(path.contains(" "))
        let url = try #require(AttachmentTarget.url(for: Attachment(kind: .file, label: "Assistant template", target: path)))
        #expect(url.isFileURL && url.path == path && url.absoluteString.contains("%20"))
        #expect(FileManager.default.isReadableFile(atPath: url.path))
        // Launch Services/Finder activation is intentionally not performed in this audit.
    }

    @Test func recordNativeApplicationMenuForAboutAndHelpAudit() {
        func items(_ menu: NSMenu?) -> [String] {
            guard let menu else { return [] }
            return menu.items.flatMap { item in
                ["\(item.title) [\(item.action.map(NSStringFromSelector) ?? "no action")]"] + items(item.submenu)
            }
        }
        print("Q3 application activation policy: \(NSApplication.shared.activationPolicy().rawValue)")
        print("Q3 application menu: \(items(NSApplication.shared.mainMenu))")
    }
}
