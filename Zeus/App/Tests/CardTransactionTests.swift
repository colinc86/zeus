import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct CardTransactionTests {
    @Test func failedMutationsPreserveAllPublishedStateAndOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-transactions-\(UUID())")
        let url = root.appendingPathComponent("cards.json")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let store = CardStore(fileURL: url, clock: { clock.now })
        let card = Card(kind: .question, body: "Durable", createdAt: clock.now, expiresAt: clock.now.addingTimeInterval(10))
        store.add(card)
        let outgoing = Card(kind: .userMessage, body: "Pending", createdAt: clock.now, updatedAt: clock.now)
        #expect(store.addOutgoing(outgoing))
        #expect(store.setOutgoingState(.queued("Offline"), cardID: outgoing.id))
        let originalStates = store.outgoingStates
        let original = try Data(contentsOf: url)
        let originalCards = store.cards
        var arrivals = 0, responses = 0
        store.onAdd = { _ in arrivals += 1 }; store.responseHandler = { _, _ in responses += 1 }
        store.setConversationOpen(true, automaticallyMarkSeen: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        store.add(Card(kind: .message, body: "Rejected"))
        #expect(!store.update(id: card.id) { $0.body = "Unsaved edit" })
        store.dismiss(id: card.id)
        store.markSeen(id: card.id); store.markAllSeen()
        #expect(!store.markRevealed(id: card.id)); store.markAllRevealed()
        #expect(!store.respond(id: card.id, response: CardResponse(text: "Answer", device: .mac)))
        #expect(!store.addOutgoing(Card(kind: .userMessage, body: "Rejected outgoing")))
        #expect(!store.setOutgoingState(.delivered, cardID: outgoing.id))
        #expect(!store.clearConversation())
        #expect(store.outgoingStates == originalStates)
        clock.advance(11); store.expire()
        #expect(!store.respond(id: card.id, response: CardResponse(text: "Expired answer", device: .mac)))
        #expect(store.cards == originalCards && store.seenIDs.isEmpty && store.revealedIDs.isEmpty)
        #expect(arrivals == 0 && responses == 0)
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(store.retryPersistence() && store.persistenceError == nil)
        store.expire()
        #expect(store.card(id: card.id)?.status == .expired)
        #expect(CardStore(fileURL: url, clock: { clock.now }).cards == store.cards)
    }
    @Test func successfulAddCallbackSeesTheAlreadyDurableSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-transactions-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CardStore(fileURL: url)
        var observedDurable = false
        store.onAdd = { card in
            let durable = CardStore(fileURL: url).card(id: card.id)
            observedDurable = durable?.body == card.body && durable?.status == card.status
        }
        store.add(Card(kind: .message, body: "Published after disk"))
        #expect(observedDurable)
    }
}
