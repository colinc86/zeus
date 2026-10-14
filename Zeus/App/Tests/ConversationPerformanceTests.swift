import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class PerformanceMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .queued(reason: "Test") }
}

@MainActor struct ConversationPerformanceTests {
    @Test func repeatedThreadReadsDoNotRebuildAndSeenChangesDoNotInvalidateChronology() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-thread-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let model = ConversationModel(cards: store, messaging: PerformanceMessaging())
        let card = Card(kind: .message, body: "One", createdAt: Date(timeIntervalSince1970: 100))
        store.add(card)
        #expect(model.thread.count == 1)
        let builds = model.threadBuildCount
        for _ in 0..<200 { #expect(model.thread.first?.body == "One") }
        #expect(model.threadBuildCount == builds)
        store.markSeen(id: card.id); store.markRevealed(id: card.id)
        #expect(model.thread.first?.body == "One" && model.threadBuildCount == builds)
        store.update(id: card.id) { $0.body = "Updated" }
        #expect(model.thread.first?.body == "Updated" && model.threadBuildCount == builds + 1)
        let outgoing = Card(kind: .userMessage, body: "Outgoing", status: .answered)
        #expect(store.addOutgoing(outgoing))
        #expect(model.thread.last?.outcome == .unconfirmed)
        #expect(store.setOutgoingState(.queued("Saved"), cardID: outgoing.id))
        #expect(model.thread.last?.outcome == .delivery(.queued(reason: "Saved")))
        store.dismiss(id: card.id)
        #expect(model.thread.first?.isMuted == true)
    }
    @Test func indexedRulesPreserveGroupingAndSeparatedAnswerCaptions() {
        let t = Date(timeIntervalSince1970: 1791820800)
        let question = Card(id: "q", kind: .question, title: "Review?", body: "Question", sessionKey: "claude:/work", createdAt: t)
        let update = Card(id: "u", kind: .message, body: "Update", sessionKey: "claude:/work", createdAt: t.addingTimeInterval(20))
        let other = Card(id: "o", kind: .message, body: "Other", sessionKey: "codex:/work", createdAt: t.addingTimeInterval(30))
        let sources = Dictionary(uniqueKeysWithValues: [question,update,other].map { ($0.id,$0) })
        let q = ConversationEntry(id: "card:q", timestamp: t, content: .agentCard(question))
        let u = ConversationEntry(id: "card:u", timestamp: update.createdAt, content: .agentCard(update))
        let o = ConversationEntry(id: "card:o", timestamp: other.createdAt, content: .agentCard(other))
        let a = ConversationEntry(id: "answer:q", timestamp: t.addingTimeInterval(40), content: .userAnswer(cardID: question.id, response: .init(text: "Yes", device: .mac)))
        #expect(ConversationLayout.grouped(u, after: q, sources: sources))
        #expect(!ConversationLayout.grouped(o, after: u, sources: sources))
        #expect(ConversationLayout.answerCaption(a, after: q, sources: sources) == nil)
        #expect(ConversationLayout.answerCaption(a, after: o, sources: sources) == "Review?")
    }
}
