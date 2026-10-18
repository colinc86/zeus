import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Suite struct PhaseDLearningTests {
    let session = "claude:/fixture#123.1"
    func seed(_ f: LearningRuntimeFixture) throws {
        try f.journal.append(.init(id: "focus", time: f.clock.now.addingTimeInterval(-1), level: .focus, kind: .focus, payload: .init(.init(description: "Editor", text: "Stored title ‹name›"))))
        try f.journal.append(.init(id: "typing", time: f.clock.now.addingTimeInterval(-1), level: .typed, kind: .typedText, payload: .init(.init(description: "NEVER_DESCRIPTION", text: "NEVER_WORDS ‹secret›", topic: "Drafting a project update"))))
    }
    @Test func reflectionIncludesOutcomeSourcesAndSuppressionWithoutRetainedWords() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        try seed(f)
        let rule = try f.rules.addOwn(.init(sentence: "Keep synthetic updates short"), at: f.clock.now)
        try f.rules.setStatus(.proposed, id: rule.id, at: f.clock.now)
        f.box.enabled = true; f.box.context.idleSince = f.clock.now.addingTimeInterval(-601)
        f.runtime.learningContextDidChange()
        try await eventually { !f.connector.deliveries.isEmpty }
        let reflection = try #require(f.connector.deliveries.first)
        #expect(reflection.kind == .reflection)
        #expect(reflection.content.contains("turned off"))
        #expect(reflection.content.contains("explicitly"))
        #expect(reflection.content.contains("Don't propose again"))
        #expect(reflection.content.contains("Drafting a project update"))
        #expect(!reflection.content.contains("NEVER_WORDS"))
        #expect(reflection.content.utf8.count < 24_000)
    }
    @Test func journalDefaultsDenyAndReturnsOnlyPermittedSummariesWithExactReceipt() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }; try seed(f)
        let off = await f.runtime.callTool("zeus_get_journal", arguments: [:], sessionKey: session)
        #expect(!off.isError); #expect(off.structured?["items"] == []); #expect(off.text.contains("Learn from me is off"))
        f.runtime.journalAccessPolicy = { .init(enabledLevels: [.focus, .typed]) }
        let answer = await f.runtime.callTool("zeus_get_journal", arguments: ["raw": true], sessionKey: session)
        #expect(!answer.isError); #expect(answer.text.contains("Stored title ‹name›") && answer.text.contains("Drafting a project update"))
        #expect(answer.text.contains("NEVER_WORDS")); #expect(!answer.text.contains("NEVER_DESCRIPTION"))
        let receipt = try #require(f.journal.items(matching: .init()).last { $0.payload.value.text == answer.text })
        #expect(receipt.kind == .sentToAssistant); #expect(receipt.payload.value.details["sessionLabel"] == "Claude · Assistant")
        #expect(!receipt.payload.value.details["sessionID", default: ""].contains("fixture"))
        let search = await f.runtime.callTool("zeus_get_journal", arguments: ["query": "NEVER_WORDS"], sessionKey: session)
        #expect(search.structured?["items"] == [])
    }
    @Test func rawWordsFollowEnabledLevelAndReadReceiptNotAnAttempt() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }; try seed(f)
        f.runtime.journalAccessPolicy = { .init(enabledLevels: [.typed]) }
        let answer = await f.runtime.callTool("zeus_get_journal", arguments: ["raw": true], sessionKey: session, deferResultCommit: true)
        #expect(answer.text.contains("NEVER_WORDS")); #expect(!answer.text.contains("NEVER_DESCRIPTION"))
        #expect(try !f.journal.items(matching: .init()).contains { $0.kind == .sentToAssistant })
        f.runtime.recordJournalAnswerReceipt(answer, sessionKey: "other")
        #expect(try !f.journal.items(matching: .init()).contains { $0.kind == .sentToAssistant })
        f.runtime.recordJournalAnswerReceipt(answer, sessionKey: session); f.runtime.recordJournalAnswerReceipt(answer, sessionKey: session)
        #expect(try f.journal.items(matching: .init()).filter { $0.kind == .sentToAssistant }.count == 1)
        #expect(f.cards.learningNotices.last?.summary.contains("including your words") == true)
    }
    @Test func rawPictureUsesOnlyCoveredFrameAndFitsBudget() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="))
        try f.journal.appendFrame(.init(.init(heic: png, width: 1, height: 1, boxes: [], appName: "Owned", windowTitle: "NEVER_TITLE")), item: .init(id: "frame", time: f.clock.now.addingTimeInterval(-1), level: .screen, kind: .frame, payload: .init(.init(description: "NEVER_FRAME"))))
        try f.journal.append(.init(id: "description", time: f.clock.now.addingTimeInterval(-1), level: .screen, kind: .description, payload: .init(.init(description: "Reading synthetic work", details: ["frame_id": "frame"]))))
        f.runtime.journalAccessPolicy = { .init(enabledLevels: [.screen], rawLevels: [.screen]) }
        let result = await f.runtime.callTool("zeus_get_journal", arguments: ["raw": true], sessionKey: session)
        #expect(!result.isError); #expect(result.text.contains("image/jpeg")); #expect(!result.text.contains("NEVER_"))
        #expect(result.text.utf8.count < 500_000)
    }
    @Test func rangesLimitsRateAdmissionAndDeletedInflightAnswer() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }; try seed(f)
        let routing = try #require(f.runtime.routing as? FakeRouting)
        routing.onlyAssistantMayTalk = true; routing.assistantSessionKey = session
        let refused = await f.runtime.callTool("zeus_get_journal", arguments: [:], sessionKey: "other")
        #expect(refused.isError); #expect(f.runtime.journalCalls.isEmpty)
        for args: JSONValue in [["from": "2026-01-01T00:00:00Z", "to": "2026-02-01T00:00:00Z"], ["limit": 0], ["limit": 1.5], ["kinds": ["unknown"]]] {
            #expect(await f.runtime.callTool("zeus_get_journal", arguments: args, sessionKey: session).isError)
        }
        f.runtime.journalAccessPolicy = { .init(enabledLevels: [.focus]) }
        let pending = await f.runtime.callTool("zeus_get_journal", arguments: [:], sessionKey: session, deferResultCommit: true)
        try f.journal.delete(.all); f.runtime.recordJournalAnswerReceipt(pending, sessionKey: session)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        for _ in 0..<15 { _ = await f.runtime.callTool("zeus_get_journal", arguments: [:], sessionKey: session) }
        let limited = await f.runtime.callTool("zeus_get_journal", arguments: [:], sessionKey: session)
        #expect(limited.isError && limited.text.contains("20 calls"))
    }
    @Test func shadowRepeatsOnceApprovalActUndoAndDeclineAreDurable() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Draft a recap", kind: .acts)], at: f.clock.now).first)
        let args: JSONValue = ["ruleID": .string(rule.id), "wouldHave": "Drafted a synthetic recap"]
        for _ in 0..<2 { #expect(!(await f.runtime.callTool("zeus_rule_shadow", arguments: args, sessionKey: session)).isError) }
        #expect(f.rules.ruleActions.count == 1)
        let shadow = try #require(f.rules.ruleActions.first)
        f.cards.learningActions["action:" + shadow.id]?()
        #expect(f.rules.rules.first?.status == .active)
        #expect(f.rules.outcomeEvents.last?.outcome == .accepted)
        #expect(abs((f.rules.rules.first?.confidence ?? 0) - 0.7) < 0.0001)
        let acted = await f.runtime.callTool("zeus_rule_acted", arguments: ["ruleID": .string(rule.id), "did": "Drafted a synthetic recap", "undo": "Delete the synthetic draft"], sessionKey: session)
        #expect(!acted.isError)
        let record = try #require(f.rules.ruleActions.last)
        let undo = try #require(f.cards.learningActions["action:" + record.id]); undo(); undo()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.meta["kind"] == "ruleUndo" }.count == 1)
        #expect(f.rules.outcomeEvents.filter { $0.outcome == .undone }.count == 1)
        let other = try #require(f.rules.propose([.init(sentence: "Post a recap", kind: .acts)], at: f.clock.now).first)
        _ = await f.runtime.callTool("zeus_rule_shadow", arguments: ["ruleID": .string(other.id), "wouldHave": "Post the synthetic recap"], sessionKey: session)
        let decline = try #require(f.rules.ruleActions.last)
        f.cards.learningSecondaryActions["action:" + decline.id]?()
        #expect(f.rules.rules.last?.status == .retired)
        #expect(f.cards.learningNotices.first { $0.id == "action:" + decline.id }?.summary == "Got it. I won't.")
        let reopened = try PersistentRulesStore(fileURL: f.root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        #expect(reopened.outcomeEvents == f.rules.outcomeEvents && reopened.ruleActions == f.rules.ruleActions)
    }
    @Test func spendingStaysShadowAndEachExactPurchaseNeedsAnAmountAndFreshSingleUseAnswer() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Buy synthetic supplies", trigger: .init(kind: "spend"), kind: .acts)], at: f.clock.now).first)
        #expect(await f.runtime.callTool("zeus_rule_shadow", arguments: ["ruleID": .string(rule.id), "wouldHave": "Buy synthetic supplies"], sessionKey: session).isError)
        let shadow = await f.runtime.callTool("zeus_rule_shadow", arguments: ["ruleID": .string(rule.id), "wouldHave": "Buy synthetic supplies", "amount": 14, "currency": "EUR"], sessionKey: session)
        #expect(!shadow.isError)
        let action = try #require(f.rules.ruleActions.first), cardID = try #require(action.approvalCardID)
        #expect(f.cards.card(id: cardID)?.body.contains(ZeusRuntime.formattedRuleAmount(14, currency: "EUR")) == true)
        let args: JSONValue = ["ruleID": .string(rule.id), "did": "Buy synthetic supplies", "approvalID": .string(action.id)]
        #expect(await f.runtime.callTool("zeus_rule_acted", arguments: args, sessionKey: session).isError)
        f.cards.respond(id: cardID, option: "approve", label: "Approve this purchase")
        #expect(f.rules.rules.first?.status == .shadow)
        #expect(!(await f.runtime.callTool("zeus_rule_acted", arguments: args, sessionKey: session)).isError)
        #expect(await f.runtime.callTool("zeus_rule_acted", arguments: args, sessionKey: session).isError)
    }
    @Test func proposalsRequireReflectionTwoDayEvidenceAndRespectSuppression() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let args: JSONValue = ["rules": [["sentence": "Hold quiet updates", "trigger": ["state": "tests failing"], "evidence": ["day1", "day2"], "confidence": 0.7]]]
        #expect(await f.runtime.callTool("zeus_propose_rules", arguments: args, sessionKey: session).isError)
        try f.allowProposals()
        let proposed = await f.runtime.callTool("zeus_propose_rules", arguments: args, sessionKey: session)
        #expect(!proposed.isError); #expect(f.rules.rules.first?.confidence == 0.7)
        let id = try #require(f.rules.rules.first?.id)
        try f.rules.setStatus(.proposed, id: id, at: f.clock.now)
        #expect(await f.runtime.callTool("zeus_propose_rules", arguments: args, sessionKey: session).isError)
        let missingDay: JSONValue = ["rules": [["sentence": "Wait during tests", "trigger": ["state": "tests failing"], "evidence": ["day2"]]]]
        #expect(await f.runtime.callTool("zeus_propose_rules", arguments: missingDay, sessionKey: session).isError)
    }
    @Test func signalDeltasFloorsAndDailyHeldAcceptance() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let own = try f.rules.addOwn(.init(sentence: "Use short replies"), at: f.clock.now)
        let signals: [(RuleOutcome, RuleOutcomeSource, Double)] = [(.accepted,.explicit,0.1),(.accepted,.actedUnchanged,0.03),(.accepted,.heldRead,0.02),(.undone,.holdShown,-0.1),(.undone,.explicit,-0.3),(.skipped,.shadowDeclined,-0.2),(.skipped,.timedQuestion,-0.1),(.ignored,.resultIgnored,-0.05),(.toggledOff,.explicit,-0.3),(.toggledOn,.explicit,0.1),(.stale,.stale,-0.1)]
        for (i, entry) in signals.enumerated() {
            try f.rules.recordSignal(entry.0, source: entry.1, ruleIDs: [own.id], eventID: "event\(i)", at: f.clock.now)
            #expect(f.rules.outcomeEvents.last?.delta == entry.2)
        }
        #expect(f.rules.rules.first?.status != .retired)
        let count = f.rules.outcomeEvents.count
        try f.rules.recordSignal(.accepted, source: .heldRead, ruleIDs: [own.id], eventID: "another", at: f.clock.now)
        #expect(f.rules.outcomeEvents.count == count)
        try f.rules.edit(id: own.id, sentence: "Use concise replies", trigger: .init(), at: f.clock.now)
        #expect((f.rules.rules.first?.confidence ?? 0) >= 0.6)
    }
    @Test func elapsedAcceptanceIgnoredShadowStaleAndRestoreFloor() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rules = try f.rules.propose([.init(sentence: "Timed quiet", trigger: .init(state: "tests failing")), .init(sentence: "Draft recap", kind: .acts)], at: f.clock.now)
        try f.rules.recordAction(.init(id: "shadow", ruleID: rules[1].id, sessionKey: session, text: "Draft recap", created: f.clock.now, kind: .shadow))
        try f.rules.recordAction(.init(id: "acted", ruleID: rules[0].id, sessionKey: session, text: "Prepared list", created: f.clock.now, kind: .acted))
        try f.rules.advanceOutcomes(at: f.clock.now.addingTimeInterval(86400)); try f.rules.advanceOutcomes(at: f.clock.now.addingTimeInterval(86400))
        #expect(f.rules.outcomeEvents.count == 2)
        #expect(f.rules.outcomeEvents.contains { $0.source == .actedUnchanged && $0.delta == 0.03 })
        #expect(f.rules.outcomeEvents.contains { $0.source == .shadowIgnored && $0.delta == -0.05 })
        try f.rules.advanceOutcomes(at: f.clock.now.addingTimeInterval(150 * 86400))
        #expect(f.rules.rules.first?.status == .retired)
        try f.rules.setStatus(.active, id: rules[0].id, at: f.clock.now.addingTimeInterval(150 * 86400))
        #expect(f.rules.rules.first?.confidence == 0.5 && f.rules.rules.first?.status == .active)
    }
}
