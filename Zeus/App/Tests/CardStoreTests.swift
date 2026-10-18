import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct CardStoreTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zeus-card-tests-\(UUID())").appendingPathComponent("cards.json")
    }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func runtimeRetentionBoundsTerminalHistoryAndPreservesPendingWorkAcrossReload() throws {
        let url = URL(fileURLWithPath: "/tmp/zret_" + UUID().uuidString.prefix(8)).appendingPathComponent("cards.json")
        defer { cleanup(url) }
        let store = CardStore(fileURL: url)
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<510 {
            store.add(Card(id: "history_\(index)", kind: .message, body: "Completed", createdAt: origin.addingTimeInterval(Double(index)), updatedAt: origin.addingTimeInterval(Double(index)), status: .dismissed))
        }
        store.markSeen(id: "history_0"); store.markRevealed(id: "history_0")
        let open = Card(id: "open", kind: .question, body: "Keep this question", createdAt: origin, updatedAt: origin)
        store.add(open)
        #expect(store.addOutgoing(Card(id: "outgoing", kind: .userMessage, body: "Unsaved", createdAt: origin, updatedAt: origin)))
        var pruned = 0
        store.onHistoryCleared = { pruned += 1 }
        let clock = TestRuntimeClock()
        let runtime = ZeusRuntime(cards: store, status: FakeStatus(), characters: FakeCharacters(), routing: FakeRouting(), clock: clock,
            socketPath: url.deletingLastPathComponent().appendingPathComponent("bridge.sock").path,
            ledgerURL: url.deletingLastPathComponent().appendingPathComponent("deliveries.json"), connectors: [])
        try runtime.start(); defer { runtime.stop() }
        #expect(store.cards.count == 502)
        #expect(store.card(id: "history_0") == nil && store.card(id: "history_9") == nil)
        #expect(store.card(id: "history_10") != nil && store.card(id: "history_509") != nil)
        #expect(store.card(id: open.id) != nil && store.card(id: "outgoing") != nil)
        #expect(!store.seenIDs.contains("history_0") && !store.revealedIDs.contains("history_0"))
        #expect(pruned == 1)
        store.pendingHistoryIDs = { ["history_10", "outgoing"] }
        store.retainHistory(keepingNewest: 0, pendingCardIDs: ["history_11"])
        #expect(Set(store.cards.map(\.id)) == ["history_10", "history_11", "open", "outgoing"])
        let restored = CardStore(fileURL: url)
        #expect(restored.cards == store.cards && restored.outgoingStates == store.outgoingStates)
        store.pendingHistoryIDs = { [] }
        store.retainHistory(keepingNewest: 0, pendingCardIDs: [])
        #expect(Set(store.cards.map(\.id)) == ["open", "outgoing"]) // An unconfirmed bubble outlives the runtime's view.
        #expect(store.setOutgoingState(.acked, cardID: "outgoing"))
        store.retainHistory(keepingNewest: 0, pendingCardIDs: [])
        #expect(store.cards == [open] && store.outgoingStates.isEmpty)
    }

    @Test func failedRetentionSavePreservesPublishedHistoryAndDoesNotPruneTransientState() throws {
        let url = file(); defer { cleanup(url) }
        let store = CardStore(fileURL: url)
        let card = Card(kind: .message, body: "Keep durable history", status: .dismissed)
        store.add(card); store.markSeen(id: card.id); store.markRevealed(id: card.id)
        var pruned = false; store.onHistoryCleared = { pruned = true }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.retainHistory(keepingNewest: 0, pendingCardIDs: [])
        #expect(store.cards == [card] && store.seenIDs == [card.id] && store.revealedIDs == [card.id])
        #expect(store.persistenceError != nil && !pruned)
        try FileManager.default.removeItem(at: url)
        store.retainHistory(keepingNewest: 0, pendingCardIDs: [])
        #expect(store.cards.isEmpty && pruned && store.persistenceError == nil)
    }

    @Test func stackOrdersPriorityAndHighArrivalsInterrupt() {
        let url = file(); defer { cleanup(url) }
        let store = CardStore(fileURL: url)
        let low = Card(kind: .message, body: "low", priority: .low)
        let first = Card(kind: .message, body: "first")
        let high = Card(kind: .message, body: "high", priority: .high)
        let second = Card(kind: .message, body: "second")
        let newest = Card(kind: .message, body: "newest", priority: .high)
        [low, first, high, second, newest].forEach(store.add)
        #expect(store.openCards.map(\.id) == [newest.id, high.id, second.id, first.id, low.id])
    }

    @Test func responsePersistsBeforeCallbackAndIsExactlyOnceEvenWhenReentrant() throws {
        let url = file(); defer { cleanup(url) }
        let clock = TestClock()
        let store = CardStore(fileURL: url, clock: { clock.now })
        let card = Card(kind: .question, body: "Ready?", sessionKey: "claude:/test")
        store.add(card)
        var calls = 0
        let response = CardResponse(optionID: "yes", optionLabel: "Yes", respondedAt: clock.now, device: .mac)
        store.responseHandler = { answered, reply in
            calls += 1
            #expect(answered.status == .answered)
            #expect(answered.sessionKey == card.sessionKey)
            #expect(store.card(id: card.id)?.response == reply)
            let reloaded = CardStore(fileURL: url, clock: { clock.now })
            #expect(reloaded.card(id: card.id)?.response == response)
            #expect(!store.respond(id: card.id, response: response))
        }
        #expect(store.respond(id: card.id, response: response))
        #expect(!store.respond(id: card.id, response: response))
        #expect(calls == 1)
        #expect(store.openCards.isEmpty)
        #expect(store.history.first?.status == .answered)
    }

    @Test func reloadRestoresSeenOpenAndTerminalCardsWithoutReplaying() {
        let url = file(); defer { cleanup(url) }
        let clock = TestClock()
        let store = CardStore(fileURL: url, clock: { clock.now })
        let open = Card(kind: .message, body: "seen")
        let dismissed = Card(kind: .message, body: "dismiss")
        let answered = Card(kind: .question, body: "answer")
        [open, dismissed, answered].forEach(store.add)
        store.markSeen(id: open.id)
        store.dismiss(id: dismissed.id)
        let reply = CardResponse(text: "from phone", respondedAt: clock.now, device: .ios)
        store.respond(id: answered.id, response: reply)
        let reloaded = CardStore(fileURL: url, clock: { clock.now })
        var calls = 0
        reloaded.responseHandler = { _, _ in calls += 1 }
        #expect(reloaded.openCards.map(\.id) == [open.id])
        // A dismissed message stays in the conversation, muted, but never counts as unread (FX16).
        #expect(reloaded.unseenCount == 0)
        #expect(reloaded.cards.contains { $0.id == dismissed.id && $0.status == .dismissed })
        reloaded.markAllSeen()
        #expect(!reloaded.hasUnseenCards)
        #expect(reloaded.history.count == 2)
        #expect(reloaded.card(id: answered.id)?.response == reply)
        #expect(!reloaded.respond(id: answered.id, response: reply))
        #expect(calls == 0)
    }

    @Test func expiredDismissedAndMissingCardsRejectResponses() {
        let url = file(); defer { cleanup(url) }
        let clock = TestClock()
        let store = CardStore(fileURL: url, clock: { clock.now })
        let expired = Card(kind: .question, body: "expires", expiresAt: clock.now.addingTimeInterval(3))
        let dismissed = Card(kind: .question, body: "dismissed")
        [expired, dismissed].forEach(store.add)
        store.dismiss(id: dismissed.id)
        clock.advance(3)
        let reply = CardResponse(text: "late", device: .mac)
        #expect(!store.respond(id: expired.id, response: reply))
        #expect(store.card(id: expired.id)?.status == .expired)
        #expect(!store.respond(id: dismissed.id, response: reply))
        #expect(!store.respond(id: "missing", response: reply))
        #expect(store.history.count == 2)
    }

    @Test func duplicateAddDoesNotReopenOrTriggerTransient() {
        let url = file(); defer { cleanup(url) }
        let store = CardStore(fileURL: url)
        let card = Card(kind: .message, body: "original")
        var adds = 0
        store.onAdd = { _ in adds += 1 }
        store.add(card)
        store.dismiss(id: card.id)
        store.add(card)
        #expect(adds == 1)
        #expect(store.cards.count == 1)
        #expect(store.card(id: card.id)?.status == .dismissed)
    }

    @Test func updatesTimestampAndRetainsIdentityAndTerminalResponse() {
        let url = file(); defer { cleanup(url) }
        let clock = TestClock()
        let store = CardStore(fileURL: url, clock: { clock.now })
        let card = Card(kind: .question, body: "before")
        store.add(card)
        store.respond(id: card.id, response: CardResponse(text: "answer", device: .mac))
        clock.advance(10)
        #expect(store.update(id: card.id) { $0.body += " after"; $0.status = .open; $0.response = nil; $0.id = "changed" })
        #expect(store.card(id: card.id)?.body == "before after")
        #expect(store.card(id: card.id)?.updatedAt == clock.now)
        #expect(store.card(id: card.id)?.status == .answered)
        #expect(store.card(id: card.id)?.response?.text == "answer")
        #expect(!store.update(id: "missing") { $0.body = "lost" })
    }

    @Test func reloadExpiresOldOpenCards() {
        let url = file(); defer { cleanup(url) }
        let clock = TestClock()
        let store = CardStore(fileURL: url, clock: { clock.now })
        let card = Card(kind: .message, body: "TTL", expiresAt: clock.now.addingTimeInterval(5))
        store.add(card)
        clock.advance(5)
        let reloaded = CardStore(fileURL: url, clock: { clock.now })
        #expect(reloaded.openCards.isEmpty)
        #expect(reloaded.card(id: card.id)?.status == .expired)
    }

    @Test func corruptHistoryIsReportedAndPreserved() throws {
        let url = file(); defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: url)
        let store = CardStore(fileURL: url)
        #expect(store.persistenceError != nil)
        store.add(Card(kind: .message, body: "new"))
        #expect(try Data(contentsOf: url) == corrupt)
    }
}
