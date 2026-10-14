import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Observable private final class OutcomePersistenceMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var userMessageDeliveries: [UserMessageDelivery] = []
    var IDs: [String] = []
    var holdOnCall: Int?
    var nextOutcome = MessageSendResult.failed(reason: "Known unsaved failure")
    @ObservationIgnored var completion: CheckedContinuation<MessageSendResult, Never>?
    func sendUserMessage(_ text: String) async -> MessageSendResult { .failed(reason: "Correlated send required") }
    func sendUserMessage(_ text: String, deliveryID: String) async -> MessageSendResult {
        IDs.append(deliveryID)
        if IDs.count == holdOnCall { return await withCheckedContinuation { completion = $0 } }
        return nextOutcome
    }
    func finish() { let current = completion; completion = nil; current?.resume(returning: nextOutcome) }
}

@MainActor struct OutgoingOutcomePersistenceTests {
    @Test(arguments: ["conversation", "settings", "retry"])
    func knownUnsavedOutcomeReturnsAfterHistoryRepairAndRetriesTheSameID(path: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-outcome-repair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cards.json")
        let cards = CardStore(fileURL: file)
        let messaging = OutcomePersistenceMessaging()
        let model = ConversationModel(cards: cards, messaging: messaging)
        let compose = ComposeModel(cards: cards, messaging: messaging)
        messaging.holdOnCall = path == "retry" ? 2 : 1
        if path == "retry" { model.draft = "Retry known work"; _ = await model.send() }
        let sending = Task {
            if path == "settings" { compose.draft = "Settings test"; await compose.send() }
            else if path == "retry" { await model.retry(entryID: model.thread[0].id) }
            else { model.draft = "Conversation message"; _ = await model.send() }
        }
        defer { messaging.finish() }
        try await eventually { messaging.completion != nil }
        let card = try #require(cards.cards.first)
        let deliveryID = try #require(cards.outgoingDeliveryIDs[card.id])
        let before = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        messaging.finish(); await sending.value
        #expect(cards.outgoingStates[card.id] == .sending && cards.persistenceError != nil)
        #expect(!cards.retryPersistence()) // A repeated storage failure must keep the known outcome.
        try FileManager.default.removeItem(at: file)
        try before.write(to: file)
        // A successful unrelated history transaction must not hide the outstanding
        // outcome repair or claim that its older .sending caption is up to date.
        #expect(cards.update(id: card.id) { $0.title = "Saved title" })
        #expect(cards.persistenceError != nil)
        #expect(cards.retryPersistence())
        let failure = OutgoingMessageState.failed("Known unsaved failure")
        #expect(cards.outgoingStates[card.id] == failure && cards.persistenceError == nil)
        #expect(CardStore(fileURL: file).outgoingStates[card.id] == failure)
        #expect(model.thread.first?.outcome == .delivery(.failed(reason: "Known unsaved failure")))
        if path == "settings" { #expect(compose.result == .failed(reason: "Known unsaved failure")) }
        messaging.holdOnCall = nil; messaging.nextOutcome = .queued(reason: "Saved for later")
        await model.retry(entryID: try #require(model.thread.first?.id))
        #expect(messaging.IDs.count == (path == "retry" ? 3 : 2))
        #expect(Set(messaging.IDs) == [deliveryID] && cards.cards.count == 1)
        #expect(cards.outgoingStates[card.id] == .queued("Saved for later"))
        #expect(cards.outgoingDeliveryIDs[card.id] == deliveryID)
    }

    @Test func committedAckWinsOverAnAppOutcomeWaitingForHistoryRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-outcome-ack-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cards.json")
        let cards = CardStore(fileURL: file)
        let messaging = OutcomePersistenceMessaging()
        cards.observeOutgoingDeliveries(from: messaging)
        let card = Card(kind: .userMessage, body: "Known ID", status: .answered)
        #expect(cards.addOutgoing(card))
        let id = try #require(cards.outgoingDeliveryIDs[card.id]), before = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(!cards.setOutgoingState(.failed("Older result"), cardID: card.id))
        let now = Date()
        messaging.userMessageDeliveries = [.init(id: id, text: card.body, sessionKey: nil, state: .acked, reason: nil,
            createdAt: now, updatedAt: now, recovered: false)]
        try FileManager.default.removeItem(at: file); try before.write(to: file)
        #expect(cards.retryPersistence() && cards.outgoingStates[card.id] == .acked)
        #expect(cards.retryPersistence() && CardStore(fileURL: file).outgoingStates[card.id] == .acked)
    }

    @Test func genuinelyInterruptedSendStaysUnknownAfterRepairAndCannotBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-outcome-unknown-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cards.json")
        let original = CardStore(fileURL: file)
        let card = Card(kind: .userMessage, body: "Interrupted", status: .answered)
        #expect(original.addOutgoing(card))
        let cards = CardStore(fileURL: file), messaging = OutcomePersistenceMessaging()
        let model = ConversationModel(cards: cards, messaging: messaging)
        #expect(cards.retryPersistence() && cards.outgoingStates[card.id] == .sending)
        await model.retry(entryID: try #require(model.thread.first?.id))
        #expect(messaging.IDs.isEmpty && model.thread.first?.outcome == .unconfirmed)
    }
}
