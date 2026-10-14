import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class TalkMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var sent: [String] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { sent.append(text); return .delivered }
}

@MainActor struct TalkCompositionTests {
    @Test func managedTalkCannotAnswerADayOldQuestionFromAnotherSession() async throws {
        let suite = "zeus-talk-routing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-talk-routing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings); cards.onAdd = nil
        let transport = TalkMessaging(); shell.messaging.runtime = transport
        let old = Card(kind: .question, title: "QA: free text", body: "Old question", input: InputSpec(),
                       sessionKey: "claude:/Other#100.1", createdAt: Date().addingTimeInterval(-86400))
        cards.add(old)
        shell.conversation.draft = "My message for the managed assistant"
        #expect(shell.conversation.replyTarget?.id == old.id)
        shell.prepareTalkComposition()
        #expect(shell.conversation.replyTarget == nil && shell.conversation.draft == "My message for the managed assistant")
        await shell.conversation.send()
        #expect(transport.sent == ["My message for the managed assistant"])
        #expect(cards.card(id: old.id)?.status == .open && cards.card(id: old.id)?.response == nil)
        shell.conversation.rearmReplyTarget(cardID: old.id)
        #expect(shell.conversation.replyTarget?.id == old.id) // Explicit Reply remains available.
        shell.prepareTalkComposition()
        let fresh = Card(kind: .question, body: "New question", input: InputSpec(), createdAt: Date())
        cards.add(fresh)
        #expect(shell.conversation.replyTarget?.id == fresh.id)
        cards.respond(id: fresh.id, response: CardResponse(text: "Done", device: .mac))
        #expect(shell.conversation.replyTarget == nil) // No fallback to an old question.
        settings.managedSession?.enabled = false
        shell.conversation.rearmReplyTarget(cardID: old.id)
        shell.prepareTalkComposition()
        #expect(shell.conversation.replyTarget?.id == old.id) // Advanced-mode policy is preserved.
    }
    @Test func explicitHistoryReplyTargetsItsCardAndNewQuestionsStillWin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-history-reply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), transport = TalkMessaging()
        let model = ConversationModel(cards: cards, messaging: transport)
        let old = Card(kind: .question, body: "Old", input: InputSpec(), createdAt: Date().addingTimeInterval(-86400))
        let newer = Card(kind: .question, body: "Newer", input: InputSpec(), createdAt: Date())
        cards.add(old); cards.add(newer); model.beginPlainMessage()
        model.rearmReplyTarget(cardID: old.id)
        #expect(model.replyTarget?.id == old.id)
        model.clearReplyTarget()
        #expect(model.replyTarget == nil)
        model.rearmReplyTarget(cardID: old.id)
        await model.send("Intentional historical answer")
        #expect(cards.card(id: old.id)?.response?.text == "Intentional historical answer")
        #expect(cards.card(id: newer.id)?.status == .open && transport.sent.isEmpty)
        let latest = Card(kind: .question, body: "Latest", input: InputSpec(), createdAt: Date().addingTimeInterval(1))
        model.rearmReplyTarget(cardID: newer.id); cards.add(latest)
        #expect(model.replyTarget?.id == latest.id)
    }

}
