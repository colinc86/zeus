import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
private final class MessagingFake: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var outcome: MessageSendResult = .delivered
    var calls: [String] = []
    var hold = false
    var waiter: CheckedContinuation<MessageSendResult, Never>?
    func sendUserMessage(_ text: String) async -> MessageSendResult {
        calls.append(text)
        if hold { return await withCheckedContinuation { waiter = $0 } }
        return outcome
    }
}

@MainActor
struct ComposeModelTests {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("zeus-compose-tests-\(UUID())").appendingPathComponent("cards.json") }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func emptyDraftDoesNothingAndDeliveredMessageIsHistoryOnly() async {
        let url = file(); defer { cleanup(url) }
        let cards = CardStore(fileURL: url)
        let fake = MessagingFake()
        let model = ComposeModel(cards: cards, messaging: fake)
        var replies = 0
        cards.responseHandler = { _, _ in replies += 1 }
        model.draft = "  \n  "
        await model.send()
        #expect(fake.calls.isEmpty)
        #expect(cards.cards.isEmpty)
        model.draft = "  Hello\nZeus  "
        await model.send()
        #expect(fake.calls == ["Hello\nZeus"])
        #expect(model.result == .delivered)
        #expect(model.draft.isEmpty)
        #expect(!model.isSending)
        #expect(cards.openCards.isEmpty)
        #expect(cards.history.first?.kind == .userMessage)
        #expect(cards.history.first?.body == "Hello\nZeus")
        #expect(replies == 0)
        #expect(CardStore(fileURL: url).history.count == 1)
    }

    @Test func queuedClearsDraftWhileFailedKeepsItForRetry() async {
        let url = file(); defer { cleanup(url) }
        let cards = CardStore(fileURL: url)
        let fake = MessagingFake()
        let model = ComposeModel(cards: cards, messaging: fake)
        fake.outcome = .queued(reason: "Disconnected")
        model.draft = "Later"
        await model.send()
        #expect(model.result == .queued(reason: "Disconnected"))
        #expect(model.draft.isEmpty)
        fake.outcome = .failed(reason: "No target")
        model.draft = "Keep this"
        await model.send()
        #expect(model.result == .failed(reason: "No target"))
        #expect(model.draft == "Keep this")
        #expect(cards.history.count == 2)
    }

    @Test func repeatSendWhileWaitingDoesNotCreateDuplicateMessage() async throws {
        let url = file(); defer { cleanup(url) }
        let cards = CardStore(fileURL: url)
        let fake = MessagingFake(); fake.hold = true
        let model = ComposeModel(cards: cards, messaging: fake)
        model.draft = "Only once"
        let pending = Task { await model.send() }
        for _ in 0..<100 where fake.waiter == nil { await Task.yield() }
        let waiter = try #require(fake.waiter)
        #expect(model.isSending)
        #expect(!model.canSend)
        await model.send()
        #expect(fake.calls == ["Only once"])
        #expect(cards.history.count == 1)
        // An independently changed draft must not be erased by an older send completing.
        model.draft = "Next message"
        waiter.resume(returning: .delivered)
        await pending.value
        #expect(model.draft == "Next message")
        #expect(!model.isSending)
    }

    @Test func disconnectedFailureCopyAcknowledgesTheSavedBubbleAndKeepsRetryAvailable() async throws {
        let url = file(); defer { cleanup(url) }
        let cards = CardStore(fileURL: url), hub = AgentMessagingHub()
        let model = ConversationModel(cards: cards, messaging: hub)
        model.draft = "Saved locally, not delivered"; _ = await model.send()
        let reason = "Zeus isn't connected to your assistant. Retry, or check Settings → Assistant."
        let card = try #require(cards.cards.first)
        #expect(CardStore(fileURL: url).card(id: card.id)?.body == "Saved locally, not delivered")
        #expect(cards.outgoingStates[card.id] == .failed(reason) && !model.draft.isEmpty)
        hub.previewEnabled = true
        await model.retry(entryID: try #require(model.thread.first?.id))
        #expect(cards.cards.count == 1 && cards.outgoingStates[card.id] == .delivered)
    }

    @Test func previewIsOptInAndRuntimeInjectionUsesOnlyMessagingProtocol() async {
        let hub = AgentMessagingHub()
        #expect(hub.sessions.isEmpty)
        if case .failed = await hub.sendUserMessage("No runtime") {} else { Issue.record("Expected a disconnected failure") }
        let fake = MessagingFake()
        hub.runtime = fake
        #expect(await hub.sendUserMessage("Real adapter") == .delivered)
        #expect(fake.calls == ["Real adapter"])
        hub.previewEnabled = true; hub.previewOutcome = .queued
        #expect(hub.sessions.count == 2)
        if case .queued = await hub.sendUserMessage("Preview") {} else { Issue.record("Expected preview queue result") }
        #expect(fake.calls == ["Real adapter"])
        #expect(hub.previewMessages == ["Preview"])
    }
}
