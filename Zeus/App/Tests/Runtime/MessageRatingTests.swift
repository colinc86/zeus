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
    @Test func onlyUserInputResponseRowsMakeReplies() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true, ratingSimilarity: FixtureRatingSimilarity()); defer { f.stop() }
        let first = try await post(f)
        _ = try await f.runtime.rate(cardID: first.id, rating: .down, scope: .kind, label: "On-call reminder")
        try await eventually { f.runtime.ratingDeliveryTask == nil && f.runtime.sends.isEmpty }
        f.runtime.noteWorkingActivity(sessionKey: key, detail: nil, progress: nil, ttl: 60)
        let autonomous = try await post(f)
        #expect(autonomous.origin == .unprompted && autonomous.muteDecision != nil)
        _ = await f.runtime.sendUserMessage("Tell me about my shift", deliveryID: "d_user_rating")
        try await eventually { f.runtime.sends.isEmpty }
        let reply = try await post(f)
        #expect(reply.origin == .reply && reply.muteDecision == nil)
        let after = try await post(f)
        #expect(after.origin == .unprompted && after.muteDecision != nil)
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
        #expect(record.delivery.content.hasPrefix("Rating: Stop these"))
        #expect(record.delivery.content.contains("Files: Zeus/preferences.md"))
        let file = try String(contentsOf: f.root.appendingPathComponent("assistant/Zeus/preferences.md"), encoding: .utf8)
        #expect(file.contains("## Stop") && file.contains("On-call reminder"))
        #expect(!f.connector.deliveries.isEmpty)
        _ = await f.runtime.callTool("zeus_ack", arguments: ["delivery_ids": [.string(record.delivery.id)]], sessionKey: key)
        #expect(f.runtime.ledger?.record(id: record.delivery.id)?.delivery.ackedAt != nil)
        let sent = try f.journal.items(matching: .init()).first { $0.payload.value.details["delivery_id"] == record.delivery.id }
        #expect(sent?.payload.value.text == record.delivery.content)
        try f.journal.delete(.all)
        #expect(f.runtime.ratings.isEmpty && f.runtime.mutedDecisions.isEmpty)
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
}
