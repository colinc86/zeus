import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round4HistoryTests {
    @Test func seenPlainMessagesAreCappedAndClearedWithoutRemovingActiveWork() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let file = f.directory.appendingPathComponent("history.json")
        let cards = CardStore(fileURL: file, clock: { f.clock.now })
        let runtime = ZeusRuntime(cards: cards, status: f.status, characters: f.characters, routing: f.routing,
            clock: f.clock, socketPath: f.directory.appendingPathComponent("history.sock").path,
            ledgerURL: f.directory.appendingPathComponent("history-deliveries.json"), connectors: [f.connector])
        try runtime.start(); defer { runtime.stop() }
        // Read via the same UI operation used by opening a conversation.
        cards.setConversationOpen(true)
        for index in 0..<510 {
            _ = await runtime.callTool("zeus_say", arguments: ["text": .string("Message \(index)")], sessionKey: "claude:/fixture")
            if let card = cards.cards.last, card.muteDecision?.source == .dailyBudget {
                try runtime.showBudgetHeldCard(id: card.id)
                cards.markSeen(ids: [card.id])
            }
        }
        #expect(cards.cards.count == 500)
        #expect(CardStore(fileURL: file).cards.count == 500)
        cards.add(.init(id: "question", kind: .question, body: "Answer me"))
        cards.add(.init(id: "options", kind: .message, body: "Choose", options: [.init(id: "a", label: "A")]))
        cards.add(.init(id: "attachments", kind: .message, body: "Review", attachments: [.init(kind: .file, label: "Fixture", target: "/tmp/fixture")]))
        _ = cards.addOutgoing(.init(id: "outgoing", kind: .userMessage, body: "Unsaved"), deliveryID: "d_unsaved")
        cards.retainHistory(keepingNewest: 0, pendingCardIDs: [])
        #expect(Set(cards.cards.map(\.id)) == ["question", "options", "attachments", "outgoing"])
        #expect(cards.clearConversation())
        #expect(Set(CardStore(fileURL: file).cards.map(\.id)) == ["question", "options", "attachments", "outgoing"])
    }
    @Test func readingPreviouslyUnreadMessagesAppliesCapWithoutAnotherAgentCall() throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let file = f.directory.appendingPathComponent("read-history.json")
        let cards = CardStore(fileURL: file)
        for index in 0..<510 { cards.add(.init(id: "message-\(index)", kind: .message, body: "Read me")) }
        cards.retainHistory(keepingNewest: 500, pendingCardIDs: [])
        #expect(cards.cards.count == 510) // Unread messages stay protected.
        cards.markAllSeen()
        #expect(cards.cards.count == 500)
        #expect(CardStore(fileURL: file).cards.count == 500)
        #expect(cards.cards.first?.id == "message-10")
    }
}
