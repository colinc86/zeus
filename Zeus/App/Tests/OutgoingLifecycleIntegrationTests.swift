import Foundation
import Observation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class OutgoingUIFixture {
    let root = URL(fileURLWithPath: "/tmp/zuiout_" + UUID().uuidString.prefix(8))
    let suite = "zeus-outgoing-ui-\(UUID())"
    let defaults: UserDefaults
    let settings: AppSettings
    let clock = TestRuntimeClock()
    let connector = FakeConnector()
    let hub = AgentMessagingHub()
    let cards: CardStore
    let runtime: ZeusRuntime
    let model: ConversationModel
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.managedSession = AppSettings.newManagedSession(enabled: false)
        let clock = clock
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        runtime = ZeusRuntime(cards: cards, status: AvatarStatusModel(cards: cards), characters: settings, routing: settings, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [connector], targetIsDead: { _ in false })
        model = ConversationModel(cards: cards, messaging: hub, clock: { clock.now })
        try runtime.start(); hub.runtime = runtime
    }
    func connect() {
        runtime.registerSession(.init(id: UUID(), sessionKey: "claude:/fixture#123.456", agent: .claude, cwd: "/fixture", clientName: "Fixture", supportsChannel: true, tmuxPane: nil, connectedAt: clock.now))
    }
    func cleanup() { runtime.stop(); hub.runtime = nil; defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

@MainActor struct OutgoingLifecycleIntegrationTests {
    @Test func actualUIHubRuntimeChainPersistsQueueTransportAckAndClearsOnlyCompletedHistory() async throws {
        let f = try OutgoingUIFixture(); defer { f.cleanup() }
        f.connector.available = false; f.model.draft = "Persist this bubble."
        _ = await f.model.send()
        let card = try #require(f.cards.cards.first)
        let deliveryID = try #require(f.cards.outgoingDeliveryIDs[card.id])
        #expect(f.hub.userMessageDeliveries.first?.id == deliveryID)
        #expect(CardStore(fileURL: f.root.appendingPathComponent("cards.json")).outgoingDeliveryIDs[card.id] == deliveryID)
        f.connector.available = true; f.connect()
        try await eventually { f.connector.deliveries.count == 1 && f.runtime.sends.isEmpty && f.cards.outgoingStates[card.id] == .delivered }
        #expect(f.connector.deliveries[0].id == deliveryID)
        _ = try f.runtime.acknowledge(ids: [deliveryID], sessionKey: "claude:/fixture#123.456")
        try await eventually { f.cards.outgoingStates[card.id] == .acked }
        let reloaded = CardStore(fileURL: f.root.appendingPathComponent("cards.json"))
        #expect(reloaded.outgoingStates[card.id] == .acked && f.model.thread.first?.outcome == .delivery(.delivered))
        #expect(reloaded.clearConversation() && reloaded.cards.isEmpty && reloaded.outgoingDeliveryIDs.isEmpty)
    }
    @Test(arguments: [false, true]) func retentionPreservesOutgoingIdentityThroughPollingOrDiscardAndReload(discard: Bool) async throws {
        let f = try OutgoingUIFixture(); defer { f.cleanup() }
        f.settings.deliveryMethod = .polling
        let obsolete = Card(kind: .userMessage, body: "Completed old history", createdAt: f.clock.now, updatedAt: f.clock.now, status: .answered)
        #expect(f.cards.addOutgoing(obsolete))
        #expect(f.cards.setOutgoingState(.acked, cardID: obsolete.id))
        f.clock.advance(1, wake: false)
        f.model.draft = "Same text"; _ = await f.model.send()
        let old = try #require(f.cards.cards.last)
        let oldID = try #require(f.cards.outgoingDeliveryIDs[old.id])
        let unsaved = Card(kind: .userMessage, body: "Known unsaved work", createdAt: f.clock.now, updatedAt: f.clock.now, status: .answered)
        #expect(f.cards.addOutgoing(unsaved))
        #expect(f.cards.setOutgoingState(.failed("Not saved for delivery"), cardID: unsaved.id))
        let unsavedID = try #require(f.cards.outgoingDeliveryIDs[unsaved.id])
        for i in 0..<510 {
            f.clock.advance(1, wake: false)
            f.cards.add(Card(id: "retention_\(i)", kind: .message, body: "Completed history", createdAt: f.clock.now, updatedAt: f.clock.now, status: .dismissed))
        }
        f.clock.advance(1, wake: false)
        f.model.draft = "Same text"; _ = await f.model.send()
        let newest = try #require(f.cards.cards.last)
        let newestID = try #require(f.cards.outgoingDeliveryIDs[newest.id])
        #expect(oldID != newestID)
        f.runtime.retainRuntimeHistory()
        #expect(f.cards.cards.count == 502 && f.cards.card(id: obsolete.id) == nil)
        let expectedIDs = [old.id: oldID, unsaved.id: unsavedID, newest.id: newestID]
        #expect(f.cards.outgoingDeliveryIDs == expectedIDs)
        #expect(CardStore(fileURL: f.root.appendingPathComponent("cards.json")).outgoingDeliveryIDs == expectedIDs)
        let terminal: OutgoingMessageState = discard ? .discarded : .acked
        if discard { f.runtime.discardPendingDeliveries() }
        else {
            f.connect()
            let result = await f.runtime.callTool("zeus_get_responses", arguments: [:], sessionKey: "claude:/fixture#123.456")
            #expect(!result.isError)
            guard case .array(let items)? = result.structured?["items"] else { Issue.record("Expected polling items"); return }
            let ids = items.compactMap { item -> String? in
                if case .string(let id)? = item["delivery_id"] { return id }; return nil
            }
            #expect(Set(ids) == Set([oldID, newestID]))
        }
        try await eventually {
            f.cards.outgoingStates[newest.id] == terminal && (f.cards.card(id: old.id) == nil || f.cards.outgoingStates[old.id] == terminal)
        }
        let reloaded = CardStore(fileURL: f.root.appendingPathComponent("cards.json"))
        #expect(reloaded.outgoingDeliveryIDs[newest.id] == newestID && reloaded.outgoingStates[newest.id] == terminal)
        #expect(reloaded.outgoingDeliveryIDs[unsaved.id] == unsavedID && reloaded.outgoingStates[unsaved.id] == .failed("Not saved for delivery"))
        if reloaded.card(id: old.id) != nil { #expect(reloaded.outgoingDeliveryIDs[old.id] == oldID && reloaded.outgoingStates[old.id] == terminal) }
        #expect(f.connector.deliveries.isEmpty)
    }

    @Test func lostLegacyAssociationIsNotGuessedFromMatchingText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-missing-correlation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("cards.json")
        let store = CardStore(fileURL: path)
        let card = Card(kind: .userMessage, body: "Identical text", status: .answered)
        store.add(card); #expect(store.setOutgoingState(.sending, cardID: card.id))
        let now = Date()
        #expect(store.reconcileOutgoingDeliveries([.init(id: UserMessageDelivery.makeID(), text: card.body, sessionKey: nil, state: .acked,
            reason: nil, createdAt: now, updatedAt: now, recovered: true)]))
        let restored = CardStore(fileURL: path)
        #expect(restored.outgoingDeliveryIDs[card.id] == nil && restored.outgoingStates[card.id] == .sending)
    }

    @Test func recoveredSnapshotReconcilesAfterHubRuntimeInstallationAndMissingIDsStayUnknown() async throws {
        let f = try OutgoingUIFixture(); defer { f.cleanup() }
        f.model.draft = "Recover this."; _ = await f.model.send()
        let card = try #require(f.cards.cards.first); let id = try #require(f.cards.outgoingDeliveryIDs[card.id])
        f.runtime.discardPendingDeliveries()
        try await eventually { f.cards.outgoingStates[card.id] == .discarded }
        _ = f.cards.setOutgoingState(.discarded, cardID: card.id)
        let path = f.root.appendingPathComponent("recovery.json")
        let recovered = CardStore(fileURL: path)
        #expect(recovered.addOutgoing(card, deliveryID: id))
        let hub = AgentMessagingHub()
        let model = ConversationModel(cards: recovered, messaging: hub)
        #expect(recovered.outgoingStates[card.id] == .sending)
        hub.runtime = f.runtime
        try await eventually { recovered.outgoingStates[card.id] == .discarded }
        #expect(model.thread.first?.outcome == .discarded)
        #expect(recovered.reconcileOutgoingDeliveries([]) && recovered.outgoingStates[card.id] == .discarded)
        #expect(CardStore(fileURL: path).outgoingStates[card.id] == .discarded)
    }
    @Test func retryUsesTheSameDurableIDAfterRuntimeStorageFailureAndComposeUsesTheCorrelatedSeam() async throws {
        let f = try OutgoingUIFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("deliveries.json"), withIntermediateDirectories: true)
        f.model.draft = "Retry storage."; _ = await f.model.send()
        let card = try #require(f.cards.cards.first); let id = try #require(f.cards.outgoingDeliveryIDs[card.id])
        if case .failed = f.cards.outgoingStates[card.id] {} else { Issue.record("Expected unsaved failure") }
        #expect(f.cards.clearConversation() && f.cards.card(id: card.id) != nil)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("deliveries.json"))
        await f.model.retry(entryID: try #require(f.model.thread.first?.id))
        #expect(f.runtime.userMessageDeliveries.first?.id == id && f.runtime.ledger?.records.count == 1)
        let compose = ComposeModel(cards: f.cards, messaging: f.hub)
        compose.draft = "Same text"; await compose.send()
        compose.draft = "Same text"; await compose.send()
        #expect(Set(f.cards.outgoingDeliveryIDs.values).count == 3 && f.runtime.userMessageDeliveries.count == 3)
    }
    @Test func settingsTestSendResultFollowsTheSameLifecycleAsItsBubble() async throws {
        let f = try OutgoingUIFixture(); defer { f.cleanup() }
        let compose = ComposeModel(cards: f.cards, messaging: f.hub)
        compose.draft = "Settings test."; await compose.send()
        guard case .queued = compose.result else { Issue.record("Expected queued result"); return }
        f.connect()
        try await eventually { compose.result == .delivered && f.runtime.sends.isEmpty }
        let id = try #require(f.cards.outgoingDeliveryIDs.values.first)
        _ = try f.runtime.acknowledge(ids: [id], sessionKey: "claude:/fixture#123.456")
        try await eventually { f.cards.outgoingStates.values.first == .acked }
        #expect(compose.result == .delivered)
    }
    @Test func lateSendOutcomeCannotUndoAckAndLifecycleWriteFailureIsTransactional() async throws {
        let f = try OutgoingUIFixture(); defer { f.cleanup() }
        f.model.draft = "Write safely."; _ = await f.model.send()
        let card = try #require(f.cards.cards.first); let id = try #require(f.cards.outgoingDeliveryIDs[card.id])
        let record = UserMessageDelivery(id: id, text: card.body, sessionKey: nil, state: .acked, reason: nil, createdAt: f.clock.now, updatedAt: f.clock.now, recovered: false)
        let before = try Data(contentsOf: f.root.appendingPathComponent("cards.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path) }
        #expect(!f.cards.reconcileOutgoingDeliveries([record]))
        #expect(f.cards.outgoingStates[card.id] != .acked)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("cards.json")) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        #expect(f.cards.reconcileOutgoingDeliveries([record]))
        #expect(f.cards.setOutgoingState(.queued("Late"), cardID: card.id) && f.cards.outgoingStates[card.id] == .acked)
    }
}

/// The committed snapshot can advance while a caller is suspended on the send result.
@MainActor @Observable private final class AdvancingOutgoingMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var userMessageDeliveries: [UserMessageDelivery] = []
    var deliveryID: String?
    @ObservationIgnored var completion: CheckedContinuation<MessageSendResult, Never>?
    func sendUserMessage(_ text: String) async -> MessageSendResult { .failed(reason: "Use a correlated ID") }
    func sendUserMessage(_ text: String, deliveryID: String) async -> MessageSendResult {
        self.deliveryID = deliveryID
        return await withCheckedContinuation { completion = $0 }
    }
}

@MainActor struct OutgoingCompletionOrderingTests {
    @Test(arguments: [false, true]) func committedLifecycleWinsOverALateQueuedReturn(settingsCompose: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-ordering-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("cards.json")
        let cards = CardStore(fileURL: path)
        let messaging = AdvancingOutgoingMessaging()
        let conversation = ConversationModel(cards: cards, messaging: messaging)
        let compose = ComposeModel(cards: cards, messaging: messaging)
        let sending = Task {
            if settingsCompose { compose.draft = "Lifecycle race"; await compose.send() }
            else { conversation.draft = "Lifecycle race"; _ = await conversation.send() }
        }
        try await eventually { messaging.completion != nil }
        let completion = try #require(messaging.completion)
        // Resume on every failure path so the test never leaks its suspended send.
        defer { if messaging.completion != nil { completion.resume(returning: .failed(reason: "Test cleanup")) } }
        let card = try #require(cards.cards.first)
        let id = try #require(messaging.deliveryID)
        let now = Date()
        messaging.userMessageDeliveries = [.init(id: id, text: card.body, sessionKey: nil,
            state: .delivered, reason: nil, createdAt: now, updatedAt: now, recovered: false)]
        try await eventually { cards.outgoingStates[card.id] == .delivered }
        messaging.completion = nil
        completion.resume(returning: .queued(reason: "Older return"))
        await sending.value
        #expect(cards.outgoingStates[card.id] == .delivered)
        #expect(CardStore(fileURL: path).outgoingStates[card.id] == .delivered)
        #expect(conversation.thread.first?.outcome == .delivery(.delivered))
        if settingsCompose { #expect(compose.result == .delivered) }
    }
}
