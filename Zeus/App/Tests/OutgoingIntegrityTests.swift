import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor struct OutgoingIntegrityTests {
    @Test func interruptedSendHasUnconfirmedStateAndCannotBeBlindlyRetried() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-outgoing-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CardStore(fileURL: url)
        let card = Card(kind: .userMessage, body: "Maybe sent", status: .answered)
        #expect(store.addOutgoing(card))
        let hub = AgentMessagingHub(); hub.previewEnabled = true
        let restored = ConversationModel(cards: CardStore(fileURL: url), messaging: hub)
        #expect(restored.thread.first?.outcome == .unconfirmed)
        await restored.retry(entryID: "card:\(card.id)")
        #expect(hub.previewMessages.isEmpty)
    }

    @Test func composerCallbackKeepsFailedDraftAndClearsOnlyAcceptedSends() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-outgoing-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hub = AgentMessagingHub(); hub.previewEnabled = true; hub.previewOutcome = .failed
        let model = ConversationModel(cards: CardStore(fileURL: url), messaging: hub)
        model.draft = "Keep my editable text"
        await ConversationView.sendFromComposer(model)
        #expect(model.draft == "Keep my editable text")
        hub.previewOutcome = .queued
        model.draft = "Save for later"
        await ConversationView.sendFromComposer(model)
        #expect(model.draft.isEmpty)
    }

    @Test func retryRetainsAnIndependentlyEditedDraft() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-outgoing-\(UUID())/cards.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hub = AgentMessagingHub(); hub.previewEnabled = true; hub.previewOutcome = .failed
        let model = ConversationModel(cards: CardStore(fileURL: url), messaging: hub)
        model.draft = "First message"
        await model.send()
        let entry = try #require(model.thread.first)
        model.draft = "A different message"
        hub.previewOutcome = .delivered
        await model.retry(entryID: entry.id)
        #expect(model.draft == "A different message")
        #expect(model.thread.count == 1)
    }
}
