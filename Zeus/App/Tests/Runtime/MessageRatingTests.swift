import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

struct FixtureRatingSimilarity: MessageSimilarityComparing {
    var score: Double = 0.95
    func compare(_ incoming: String, with example: String) async -> MessageSimilarityResult? {
        .init(score: score, engine: "fixture", threshold: 0.8)
    }
}
@MainActor struct MessageRatingTests {
    let key = "claude:/fixture#123.1"
    func post(_ f: LearningRuntimeFixture, about: String = "On-call reminder", text: String = "Check the rotation before your shift.", priority: String = "normal") async throws -> Card {
        let result = await f.runtime.callTool("zeus_say", arguments: ["text": .string(text), "about": .string(about), "priority": .string(priority)], sessionKey: key)
        #expect(!result.isError)
        return try #require(f.cards.values.last)
    }
    @Test func exactAndSemanticHoldPrecedeAddAndHighPriorityCannotBypass() async throws {
        let f = try LearningRuntimeFixture(exportFolder: true, messageRatings: true, ratingSimilarity: FixtureRatingSimilarity()); defer { f.stop() }
        let first = try await post(f)
        #expect(first.origin == .unprompted && first.about == "On-call reminder")
        _ = try await f.runtime.rate(cardID: first.id, rating: .down, scope: .kind, label: first.about ?? "")
        var addWasHeld = false
        f.cards.onAdd = { addWasHeld = $0.muteDecision != nil }
        let exact = try await post(f, about: "ON CALL reminder", priority: "high")
        #expect(addWasHeld && exact.muteDecision?.engine == "exact")
        let similar = try await post(f, about: "Rotation heads-up")
        #expect(similar.muteDecision?.engine == "fixture" && similar.muteDecision?.reason == "looks like On-call reminder")
        #expect(f.runtime.mutedToday.count == 2 && f.cards.values.count == 3)
        var shown: [String] = []; f.runtime.onShowMuted = { shown = $0 }; f.runtime.showMuted()
        #expect(Set(shown) == Set([exact.id, similar.id]))
        let correction = try await f.runtime.correctMuted(cardID: similar.id)
        #expect(f.cards.card(id: similar.id)?.muteDecision?.releasedAt != nil)
        #expect(f.runtime.ratingUndo(for: similar.id) == correction)
        try await f.runtime.undoRating(correction)
        #expect(f.cards.card(id: similar.id)?.muteDecision?.releasedAt == nil)
        f.clock.advance(86400)
        #expect(f.runtime.mutedToday.isEmpty && f.runtime.mutedDecisions.count == 2)
    }
    func turnEnded(_ f: LearningRuntimeFixture, id: String?) -> TurnEnded {
        .init(agent: .claude, pid: 99, ppid: 123, cwd: "/fixture", ancestors: [.init(pid: 123, startTime: 1)],
              firedAt: f.clock.now.timeIntervalSince1970, reason: .completed, nativeSessionID: nil, deliveryID: id)
    }
    /// Regression: only the first message of an answer was a reply; the rest were unprompted and a Stop rating muted them.
    @Test func everyMessageInAnAnswerIsAReplyUntilAnotherDeliveryArrives() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true, ratingSimilarity: FixtureRatingSimilarity()); defer { f.stop() }
        let first = try await post(f)
        _ = try await f.runtime.rate(cardID: first.id, rating: .down, scope: .kind, label: "On-call reminder")
        try await eventually { f.runtime.ratingDeliveryTask == nil && f.runtime.sends.isEmpty }
        // A status alone never makes a reply.
        f.runtime.noteWorkingActivity(sessionKey: key, detail: nil, progress: nil, ttl: 60)
        let autonomous = try await post(f)
        #expect(autonomous.origin == .unprompted && autonomous.muteDecision != nil)
        _ = await f.runtime.sendUserMessage("Tell me about my shift", deliveryID: "d_user_rating")
        try await eventually { f.runtime.sends.isEmpty }
        // The first, second and third messages of the answer are all replies; Stop these never mutes a reply.
        for _ in 0..<3 {
            let reply = try await post(f)
            #expect(reply.origin == .reply && reply.muteDecision == nil && !reply.isRatingHeld)
        }
        f.runtime.noteWorkingActivity(sessionKey: key, detail: "Checking", progress: nil, ttl: 60)
        #expect(try await post(f).origin == .reply)
        // Any delivery from Zeus that isn't the user's (here a restart notice) reaching the session ends the answer.
        try f.runtime.ledger?.insert(.init(delivery: .init(id: "restart_note", kind: .restart, sessionKey: key, content: "Synthetic restart notice", createdAt: f.clock.now)))
        f.runtime.processDueDeliveries()
        try await eventually { f.connector.deliveries.last?.id == "restart_note" && f.runtime.sends.isEmpty }
        let after = try await post(f)
        #expect(after.origin == .unprompted && after.muteDecision != nil)
    }
    @Test func anAnswerEndsWithItsTurnOrAfterHalfAnHourIdle() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true); defer { f.stop() }
        _ = await f.runtime.sendUserMessage("First question", deliveryID: "d_turn")
        try await eventually { f.runtime.sends.isEmpty }
        #expect(try await post(f).origin == .reply)
        #expect(try await post(f).origin == .reply)
        // A hook naming another input belongs to another turn.
        await f.runtime.bridgeTurnEnded(turnEnded(f, id: "d_other"))
        #expect(try await post(f).origin == .reply)
        await f.runtime.bridgeTurnEnded(turnEnded(f, id: "d_turn"))
        #expect(try await post(f).origin == .unprompted)
        // A hook without an input ID still ends the turn it fired after.
        _ = await f.runtime.sendUserMessage("Second question", deliveryID: "d_turn_2")
        try await eventually { f.runtime.sends.isEmpty }
        #expect(try await post(f).origin == .reply)
        await f.runtime.bridgeTurnEnded(turnEnded(f, id: nil))
        #expect(try await post(f).origin == .unprompted)
        // External sessions without hooks: tool traffic keeps the answer open; half an hour of quiet ends it.
        _ = await f.runtime.sendUserMessage("Third question", deliveryID: "d_idle")
        try await eventually { f.runtime.sends.isEmpty }
        #expect(try await post(f).origin == .reply)
        f.clock.advance(29 * 60, wake: false)
        _ = await f.runtime.callTool("zeus_set_status", arguments: ["state": "auto"], sessionKey: key)
        f.clock.advance(29 * 60, wake: false)
        #expect(try await post(f).origin == .reply)
        f.clock.advance(ZeusRuntime.replyWindowIdleCap, wake: false)
        #expect(try await post(f).origin == .unprompted)
    }
    @Test func reconnectingTheSessionEndsTheAnswer() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true); defer { f.stop() }
        _ = await f.runtime.sendUserMessage("A question", deliveryID: "d_reconnect")
        try await eventually { f.runtime.sends.isEmpty }
        #expect(try await post(f).origin == .reply)
        f.runtime.registerSession(.init(id: UUID(), sessionKey: key, agent: .claude, cwd: "/fixture", clientName: "Fixture", supportsChannel: true, tmuxPane: nil, connectedAt: f.clock.now))
        #expect(try await post(f).origin == .unprompted)
    }
    @Test func justOneNeutralLabelEditsAndGuardedDurableUndo() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true, ratingSimilarity: FixtureRatingSimilarity(score: 0)); defer { f.stop() }
        let first = try await post(f)
        _ = try await f.runtime.rate(cardID: first.id, rating: .down, scope: .justThisOne, label: "On-call reminder")
        #expect(try await post(f).muteDecision == nil)
        let token = try await f.runtime.rate(cardID: first.id, rating: .neutral, scope: .kind, label: "On-call reminder")
        let rating = try #require(f.runtime.ratings.first { $0.scope == .kind })
        let reloaded = try MessageRatingStore(fileURL: f.root.appendingPathComponent("ratings.zratings"), keyProvider: FixtureJournalKey())
        #expect(reloaded.state.undos.first?.id == token.id)
        #expect(try await post(f).muteDecision == nil)
        _ = try await f.runtime.update(id: rating.id, rating: .down, scope: .kind, label: "Meeting prep")
        #expect(f.runtime.ratings.first { $0.id == rating.id }?.kindKey == "meeting prep")
        #expect(f.runtime.ratingUndo(for: rating.id) != token)
        do { try await f.runtime.undoRating(token); Issue.record("Stale undo overwrote a later edit") } catch { }
        #expect(try await post(f).muteDecision == nil)
        #expect(try await post(f, about: "Meeting prep").muteDecision != nil)
        _ = try await f.runtime.remove(id: rating.id)
        #expect(try await post(f, about: "Meeting prep").muteDecision == nil)
    }
    @Test func ratingDeliveryIsDurableIndependentOfLearningSwitchAndAckKeepsExactFileLine() async throws {
        let f = try LearningRuntimeFixture(exportFolder: true, messageRatings: true, ratingSimilarity: FixtureRatingSimilarity()); defer { f.stop() }
        #expect(!f.runtime.learnings.learningsEnabled)
        let first = try await post(f)
        _ = try await f.runtime.rate(cardID: first.id, rating: .down, scope: .kind, label: "On-call reminder")
        try await eventually { f.runtime.ratingDeliveryTask == nil && f.runtime.sends.isEmpty }
        let record = try #require(f.runtime.ledger?.records.first { $0.delivery.meta["learning_kind"] == "rating" })
        let appCards = CardStore(fileURL: f.root.appendingPathComponent("app-cards.json"))
        let presentation = LearningDeliveryModel(cards: appCards, source: { f.runtime }, clock: { f.clock.now })
        f.runtime.publishPendingLearnings(f.runtime.ledger?.records ?? []); presentation.reconcile()
        #expect(presentation.pending.contains { $0.id == record.delivery.id && $0.isMessagePreference })
        #expect(appCards.notices.isEmpty)

        #expect(record.delivery.content.hasPrefix("Rating: Stop these"))
        #expect(record.delivery.content.contains("Files: Zeus/preferences.md"))
        let file = try String(contentsOf: f.root.appendingPathComponent("assistant/Zeus/preferences.md"), encoding: .utf8)
        #expect(file.contains("## Stop") && file.contains("On-call reminder"))
        #expect(!f.connector.deliveries.isEmpty)
        _ = await f.runtime.callTool("zeus_ack", arguments: ["delivery_ids": [.string(record.delivery.id)]], sessionKey: key)
        #expect(f.runtime.ledger?.record(id: record.delivery.id)?.delivery.ackedAt != nil)
        let sent = try f.journal.items(matching: .init()).first { $0.payload.value.details["delivery_id"] == record.delivery.id }
        #expect(sent?.payload.value.text == record.delivery.content)
        presentation.reconcile()
        #expect(appCards.notices.isEmpty)
        #expect(sent?.payload.value.details["kind"] == "rating")
        #expect(!f.cards.learningNotices.contains { $0.id == "n_" + record.delivery.id })
        try f.journal.delete(.all)
        #expect(f.runtime.ratings.isEmpty && f.runtime.mutedDecisions.isEmpty)
        await f.folder?.flush()
        #expect(f.runtime.ratingDeliveryTask == nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("assistant/Zeus/preferences.md").path))
        _ = await f.runtime.callTool("zeus_ack", arguments: ["delivery_ids": [.string(record.delivery.id)]], sessionKey: key)
        #expect(try f.journal.items(matching: .init()).isEmpty)
    }
    @Test func quietSignalsSuggestOnceAfterFiveWithoutMuting() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true); defer { f.stop() }
        for _ in 0..<4 { _ = try await post(f) }
        f.clock.advance(86400)
        f.runtime.scheduleRatingSuggestions()
        #expect(f.runtime.ratingSuggestions.isEmpty)
        let fifth = try await post(f)
        f.runtime.ratingCardShown(id: fifth.id); f.clock.advance(2); f.runtime.ratingCardDismissed(id: fifth.id)
        let suggestion = try #require(f.runtime.ratingSuggestions.first)
        #expect(suggestion.count == 5 && suggestion.exampleCardID == fifth.id)
        #expect(f.runtime.mutedDecisions.isEmpty)
        try f.runtime.dismissRatingSuggestion(id: suggestion.id)
        _ = try await post(f); f.clock.advance(86400); f.runtime.scheduleRatingSuggestions()
        #expect(f.runtime.ratingSuggestions.isEmpty)
    }
    @Test func invalidAboutCannotBePosted() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true); defer { f.stop() }
        for about in ["", String(repeating: "x", count: 61), "two\nlines"] {
            let result = await f.runtime.callTool("zeus_say", arguments: ["text": "hello", "about": .string(about)], sessionKey: key)
            #expect(result.isError)
        }
        #expect(f.cards.values.isEmpty)
    }
    @Test func invalidAboutLeavesUserResponseOpenAndAskPresentClassifyBeforeEndingIt() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true); defer { f.stop() }
        _ = await f.runtime.sendUserMessage("A user question", deliveryID: "d_rating_origin")
        try await eventually { f.runtime.sends.isEmpty }
        let bad = await f.runtime.callTool("zeus_say", arguments: ["text": "hello", "about": ""], sessionKey: key)
        #expect(bad.isError && f.runtime.assistantActivity != nil)
        let ask = await f.runtime.callTool("zeus_ask", arguments: ["text": "Which?", "about": "Follow-up", "wait_seconds": 0], sessionKey: key)
        #expect(!ask.isError && f.cards.values.last?.origin == .reply)
        f.cards.respond(id: try #require(f.cards.values.last?.id), text: "This one")
        try await eventually { f.runtime.sends.isEmpty }
        let present = await f.runtime.callTool("zeus_present", arguments: ["title": "Result", "body": "Here it is", "about": "Finished work"], sessionKey: key)
        #expect(!present.isError && f.cards.values.last?.origin == .reply)
    }
    @Test func ratingOutboxDrainsWithoutReplayAndDeleteEverythingCancelsPendingRating() async throws {
        let f = try LearningRuntimeFixture(exportFolder: true, messageRatings: true); defer { f.stop() }
        let card = try await post(f)
        _ = try await f.runtime.rate(cardID: card.id, rating: .up, scope: .kind, label: "On-call reminder")
        try await eventually { f.runtime.ratingDeliveryTask == nil && f.runtime.sends.isEmpty }
        #expect(f.ratingStore?.state.outbox.isEmpty == true)
        let deliveryID = try #require(f.runtime.ledger?.records.first { $0.delivery.meta["learning_kind"] == "rating" }?.delivery.id)
        try f.journal.delete(.all)
        #expect(f.runtime.ledger?.record(id: deliveryID)?.discardedAt != nil)
        #expect(f.ratingStore?.state.ratings.isEmpty == true)
        f.runtime.recordReflectionReceipt(id: deliveryID)
        #expect(try f.journal.items(matching: .init()).isEmpty)
    }
    @Test func semanticNonmatchAndAlreadyReadMessagesDoNotMuteOrSuggest() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true, ratingSimilarity: FixtureRatingSimilarity(score: 0.2)); defer { f.stop() }
        let first = try await post(f)
        _ = try await f.runtime.rate(cardID: first.id, rating: .down, scope: .kind, label: "On-call reminder")
        for _ in 0..<6 {
            let card = try await post(f, about: "Build results", text: "Your requested build passed.")
            #expect(card.muteDecision == nil)
            f.runtime.ratingCardOpened(id: card.id)
        }
        f.clock.advance(86400); f.runtime.scheduleRatingSuggestions()
        #expect(f.runtime.ratingSuggestions.isEmpty)
    }
    @Test func savedOutboxRetriesLedgerWriteWithoutAnotherUserAction() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true); defer { f.stop() }
        let card = try await post(f)
        try await eventually { f.runtime.ratingDeliveryTask == nil }
        let ledgerURL = f.root.appendingPathComponent("deliveries.json")
        if FileManager.default.fileExists(atPath: ledgerURL.path) { try FileManager.default.removeItem(at: ledgerURL) }
        try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: true)
        _ = try await f.runtime.rate(cardID: card.id, rating: .down, scope: .kind, label: "On-call reminder")
        try await eventually { f.runtime.ratingRetryTask != nil && f.runtime.ratingDeliveryTask == nil }
        #expect(f.ratingStore?.state.outbox.count == 1)
        try FileManager.default.removeItem(at: ledgerURL)
        f.clock.advance(3)
        try await eventually { f.ratingStore?.state.outbox.isEmpty == true && !f.connector.deliveries.isEmpty }
        #expect(f.runtime.ratingsError == nil)
    }
    @Test func encryptedStoreLockedLoadCannotOverwriteAndEraseNeedsNoKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb1_keys_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ratings.zratings"), key = RatingFixtureKey()
        let store = try MessageRatingStore(fileURL: url, keyProvider: key)
        var state = store.state
        state.ratings = [.init(id: "r1", kindLabel: "Synthetic preference", kindKey: "synthetic preference", rating: .down, scope: .kind,
            exampleCardID: "c1", exampleText: "Only ‹email› remains", createdAt: Date(), updatedAt: Date())]
        try store.commit(state)
        let bytes = try Data(contentsOf: url)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("Synthetic preference"))
        key.locked = true
        let locked = try MessageRatingStore(fileURL: url, keyProvider: key)
        #expect(!locked.isReady && locked.storageWaitingForUnlock)
        do { try locked.commit(.init()); Issue.record("Locked preferences were overwritten") } catch { }
        #expect(try Data(contentsOf: url) == bytes)
        key.locked = false; locked.retryPendingWrites()
        #expect(locked.state.ratings.count == 1 && locked.isReady)
        key.locked = true
        try locked.clear()
        #expect(locked.state.ratings.isEmpty && !FileManager.default.fileExists(atPath: url.path))
        try Data("corrupt fixture".utf8).write(to: url)
        key.locked = false
        #expect(throws: (any Error).self) { try MessageRatingStore(fileURL: url, keyProvider: key) }
        #expect(try Data(contentsOf: url) == Data("corrupt fixture".utf8))
    }

}

@MainActor private final class RatingFixtureKey: FixtureLearningKeyProviding {
    var locked = false
    func key() throws -> Data {
        if locked { throw LearningStorageError.keyUnavailable }
        return Data(repeating: 7, count: 32)
    }
}
