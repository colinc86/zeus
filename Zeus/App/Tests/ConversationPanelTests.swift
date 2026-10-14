import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class PanelMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var outcome: MessageSendResult = .failed(reason: "Offline")
    var calls: [String] = []
    var deliveryIssue: DeliveryIssue?
    var retries = 0
    var discards = 0
    func retryPendingDeliveries() { retries += 1 }
    func discardPendingDeliveries() { discards += 1; deliveryIssue = nil }
    func sendUserMessage(_ text: String) async -> MessageSendResult { calls.append(text); return outcome }
}

@MainActor private final class PasswordMemory: OpenCodePasswordStoring {
    var value: String?
    var fail = false
    var reads = 0
    enum Failure: Error { case unavailable }
    func read() throws -> String? { reads += 1; if fail { throw Failure.unavailable }; return value }
    func save(_ password: String?) throws { if fail { throw Failure.unavailable }; value = password }
}

@MainActor struct ConversationPanelTests {
    @Test func viewportControlledUnreadSurvivesOpenAndUpdatesUntilActuallySeen() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-panel-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cards = CardStore(fileURL: url)
        let model = ConversationModel(cards: cards, messaging: PanelMessaging())
        let first = Card(kind: .message, body: "First")
        cards.add(first); model.openPanel(viewportManaged: true)
        #expect(cards.unseenCount == 1)
        let second = Card(kind: .progress, body: "Working")
        cards.add(second); cards.update(id: second.id) { $0.progress = 0.5 }
        #expect(cards.unseenCount == 2)
        cards.markSeen(id: second.id)
        #expect(cards.unseenCount == 1)
        model.closePanel()
        #expect(CardStore(fileURL: url).seenIDs == [second.id])
    }

    @Test func retryKeepsOneBubbleAndNeverAnswersAnIncomingQuestion() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-panel-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cards = CardStore(fileURL: url), messaging = PanelMessaging()
        let model = ConversationModel(cards: cards, messaging: messaging)
        await model.send("Original")
        let id = model.thread[0].id
        let question = Card(kind: .question, body: "New", input: InputSpec())
        cards.add(question)
        messaging.outcome = .delivered
        await model.retry(entryID: id)
        #expect(messaging.calls == ["Original", "Original"])
        #expect(model.thread.filter(\.isUser).count == 1)
        #expect(model.thread.first { $0.id == id }?.outcome == .delivery(.delivered))
        #expect(cards.card(id: question.id)?.response == nil)
        await model.retry(entryID: id)
        #expect(messaging.calls.count == 2)
    }

    @Test func contentShortcutsSkipQuestionsWithoutOptionsAndKeepSuppliedOrder() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-panel-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cards = CardStore(fileURL: url)
        let model = ConversationModel(cards: cards, messaging: PanelMessaging())
        cards.add(Card(kind: .question, body: "Old", options: [CardOption(id: "old", label: "Old")], createdAt: Date(timeIntervalSince1970: 1)))
        let content = Card(kind: .content, body: "File", options: [CardOption(id: "one", label: "One"), CardOption(id: "two", label: "Two", style: .primary)], createdAt: Date(timeIntervalSince1970: 2))
        cards.add(content)
        cards.add(Card(kind: .question, body: "Text only", input: InputSpec(), createdAt: Date(timeIntervalSince1970: 3)))
        #expect(model.shortcutTarget?.id == content.id)
        #expect(model.pickNumberedOption(2))
        #expect(cards.card(id: content.id)?.response?.optionID == "two")
    }

    @Test func groupingDependsOnSpeakerSessionAndTwoMinuteBoundary() {
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let a = Card(kind: .message, body: "A", sessionKey: "claude:/Zeus", createdAt: now)
        let b = Card(kind: .message, body: "B", sessionKey: "claude:/Zeus", createdAt: now.addingTimeInterval(119))
        let c = Card(kind: .message, body: "C", sessionKey: "codex:/Zeus", createdAt: now.addingTimeInterval(120))
        let entry: (Card) -> ConversationEntry = { ConversationEntry(id: $0.id, timestamp: $0.createdAt, content: .agentCard($0)) }
        #expect(ConversationLayout.grouped(entry(b), after: entry(a), cards: [a,b,c]))
        #expect(!ConversationLayout.grouped(entry(c), after: entry(b), cards: [a,b,c]))
        var later = b; later.createdAt = now.addingTimeInterval(120)
        #expect(!ConversationLayout.grouped(entry(later), after: entry(a), cards: [a,b]))
        #expect(ConversationLayout.needsDivider(entry(a), after: nil))
        later.createdAt = now.addingTimeInterval(601)
        #expect(ConversationLayout.needsDivider(entry(later), after: entry(a)))
        later.createdAt = now.addingTimeInterval(600)
        #expect(!ConversationLayout.needsDivider(entry(later), after: entry(a)))
        #expect(ConversationLayout.sessionLabel(key: "codex:/work/Zeus#%3", sessions: []) == "Codex · Zeus · pane 3")
        #expect(ConversationLayout.sessionLabel(key: "claude:#%3", sessions: []) == "Agent session")
        #expect(ConversationLayout.sessionLabel(key: "", sessions: []) == "Agent session")
    }

    @Test func sizeAndViewportRespectLimitsIncludingShortScreens() {
        #expect(ConversationLayout.threadHeight(content: 10, composer: 40, screen: 900) == 160)
        #expect(ConversationLayout.threadHeight(content: 1000, composer: 40, screen: 900) == 520)
        #expect(ConversationLayout.threadHeight(content: 1000, composer: 200, screen: 600) == 156)
        #expect(ConversationLayout.isAtBottom(lastBottom: 224, viewportHeight: 200))
        #expect(!ConversationLayout.isAtBottom(lastBottom: 225, viewportHeight: 200))
        #expect(!ConversationLayout.intersects(CGRect(x: 0, y: -80, width: 100, height: 80), viewportHeight: 200))
        #expect(ConversationLayout.intersects(CGRect(x: 0, y: 190, width: 100, height: 80), viewportHeight: 200))
    }

    @Test func jumpCountIgnoresUnseenHistoryAboveAndCountsOnlyAgentItemsBelow() {
        let cards = (0..<5).map { Card(id: "\($0)", kind: $0 == 3 ? .userMessage : .message, body: "\($0)") }
        let entries = cards.map { ConversationEntry(id: "entry:\($0.id)", timestamp: $0.createdAt, content: $0.kind == .userMessage ? .userMessage($0) : .agentCard($0)) }
        #expect(ConversationLayout.unseenBelow(entries: entries, visible: ["entry:1"], seen: []) == 2)
        #expect(ConversationLayout.unseenBelow(entries: entries, visible: ["entry:1"], seen: ["2"]) == 1)
        #expect(ConversationLayout.unseenBelow(entries: entries, visible: ["entry:4"], seen: []) == 0)
        #expect(ConversationLayout.unseenBelow(entries: entries, visible: [], seen: []) == 0)
    }

    @Test func controlsWithRepeatedAgentIDsHaveDifferentNativeFocusTargets() {
        let first = ConversationControlTarget(entryID: "card:first", controlID: "option:yes")
        let second = ConversationControlTarget(entryID: "card:second", controlID: "option:yes")
        let attachment = ConversationControlTarget(entryID: "card:first", controlID: "open:yes")
        #expect(Set([first, second, attachment]).count == 3)
    }

    @Test func bubbleAccessibilityMetadataNamesItsSpeakerWithoutRepeatingTheBody() {
        let now = Date()
        let card = Card(kind: .message, title: "Result", body: "A body spoken by its text child", sessionKey: "codex:/work/Zeus", createdAt: now)
        let entry = ConversationEntry(id: card.id, timestamp: now, content: .agentCard(card))
        let label = ConversationLayout.accessibilityLabel(entry, sessions: [])
        #expect(label.hasPrefix("Codex, Result, "))
        #expect(!label.contains(card.body))
        var openCode = card; openCode.sessionKey = "opencode:/work/Zeus"
        let openCodeEntry = ConversationEntry(id: openCode.id, timestamp: now, content: .agentCard(openCode))
        #expect(ConversationLayout.accessibilityLabel(openCodeEntry, sessions: []).hasPrefix("OpenCode, Result, "))
        let user = Card(kind: .userMessage, body: "My reply")
        let userEntry = ConversationEntry(id: user.id, timestamp: now, content: .userMessage(user))
        let userLabel = ConversationLayout.accessibilityLabel(userEntry, sessions: [])
        #expect(userLabel.hasPrefix("You, ") && !userLabel.contains(". "))
    }

    @Test func passwordUsesInjectedKeychainOnlyAndPreferredAgentTracksBackend() throws {
        let name = "zeus-password-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let password = PasswordMemory()
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: password)
        #expect(password.reads == 0)
        #expect(settings.preferredAgent == .claude)
        settings.backend = .codex
        #expect(settings.preferredAgent == .codex)
        settings.backend = .opencode
        #expect(settings.preferredAgent == .opencode)
        #expect(settings.saveOpenCodePassword("test-secret"))
        #expect(settings.openCodeServerPassword == "test-secret")
        #expect(!defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("test-secret") })
        password.fail = true
        #expect(!settings.saveOpenCodePassword("new-secret"))
        #expect(settings.passwordError != nil)
        #expect(password.value == "test-secret")
        password.fail = false
        #expect(settings.saveOpenCodePassword(nil))
        #expect(settings.openCodeServerPassword == nil)
        #expect(settings.passwordError == nil)
    }

    @Test func previewWarningActionsNeverReachRuntimeAndActivityExpires() {
        let hub = AgentMessagingHub()
        let runtime = PanelMessaging()
        runtime.deliveryIssue = DeliveryIssue(title: "Real runtime", detail: "Pending", pendingCount: 1, since: Date())
        hub.runtime = runtime
        hub.previewEnabled = true
        hub.previewDeliveryIssue = DeliveryIssue(title: "Offline", detail: "Two pending", pendingCount: 2, since: Date())
        hub.previewOutcome = .failed
        hub.retryPendingDeliveries()
        #expect(hub.deliveryIssue != nil)
        hub.previewOutcome = .delivered
        hub.retryPendingDeliveries()
        #expect(hub.deliveryIssue == nil)
        hub.previewDeliveryIssue = DeliveryIssue(title: "Offline", detail: "Two pending", pendingCount: 2, since: Date())
        hub.discardPendingDeliveries()
        #expect(hub.deliveryIssue == nil)
        #expect(runtime.retries == 0 && runtime.discards == 0)
        hub.previewEnabled = false
        #expect(hub.deliveryIssue == runtime.deliveryIssue)
        hub.retryPendingDeliveries()
        #expect(runtime.retries == 1)
        hub.discardPendingDeliveries()
        #expect(runtime.discards == 1 && hub.deliveryIssue == nil)
        let clock = TestClock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-panel-\(UUID())/cards.json")
        let cards = CardStore(fileURL: url, clock: { clock.now })
        let status = AvatarStatusModel(cards: cards, clock: { clock.now })
        status.setOverride(.thinking, detail: "Planning", progress: nil, ttl: 10)
        #expect(status.activity?.detail == "Planning")
        clock.advance(10); status.tick()
        #expect(status.activity == nil)
    }
}
