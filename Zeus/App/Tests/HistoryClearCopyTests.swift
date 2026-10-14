import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct HistoryClearCopyTests {
    @Test func clearCaptionMatchesTheReadMessageAndActiveWorkPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-clear-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let read = Card(kind: .message, body: "Read, still open")
        let completed = Card(kind: .question, body: "Completed", status: .answered)
        let unread = Card(kind: .message, body: "Unread")
        let question = Card(kind: .question, body: "Open question", input: InputSpec())
        let action = Card(kind: .message, body: "Open action", options: [.init(id: "do", label: "Do it")])
        for card in [read, completed, unread, question, action] { cards.add(card) }
        cards.markSeen(id: read.id); cards.markSeen(id: question.id); cards.markSeen(id: action.id)
        var keptIDs: Set<String> = [unread.id, question.id, action.id]
        for state in [OutgoingMessageState.sending, .queued("Offline"), .failed("Not saved by runtime"), .delivered] {
            let card = Card(kind: .userMessage, body: "Protected \(state)", status: .answered)
            #expect(cards.addOutgoing(card) && cards.setOutgoingState(state, cardID: card.id))
            keptIDs.insert(card.id)
        }
        let caption = GeneralSettingsView.historyCaption(count: cards.cards.count)
        #expect(caption.contains("Clearing removes read messages and completed history."))
        #expect(caption.contains("Unread messages, open questions and actions, and unsent or unconfirmed messages are kept."))
        #expect(caption.contains(ConversationHistoryCopy.preservation))
        #expect(ConversationHistoryCopy.confirmation.contains("Clearing removes read messages and completed history."))
        #expect(ConversationHistoryCopy.confirmation.contains("Unread messages, open questions and actions, and unsent or unconfirmed messages are kept."))
        #expect(ConversationHistoryCopy.confirmation.hasSuffix("Messages already on their way are still delivered."))
        #expect(cards.clearConversation())
        #expect(Set(cards.cards.map(\.id)) == keptIDs)
        let reload = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        #expect(Set(reload.cards.map(\.id)) == keptIDs)
        #expect(reload.cards.map(\.body) == cards.cards.map(\.body))
        #expect(reload.outgoingStates == cards.outgoingStates && reload.outgoingDeliveryIDs == cards.outgoingDeliveryIDs)
    }
}
