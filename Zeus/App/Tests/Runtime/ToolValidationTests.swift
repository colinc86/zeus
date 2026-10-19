import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Suite struct ToolValidationTests {
    let session = "claude:/fixture#123.1"

    @Test func pendingPurchaseOnlyReplaysExactValidatedRequestFromSameSession() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Buy supplies", trigger: .init(kind: "spend"), kind: .acts)], at: f.clock.now).first)
        func request(_ text: String = "Buy paper", amount: JSONValue = 14, currency: JSONValue = "USD") -> JSONValue {
            ["ruleID": .string(rule.id), "wouldHave": .string(text), "amount": amount, "currency": currency]
        }
        let first = await f.runtime.callTool("zeus_rule_shadow", arguments: request(), sessionKey: session)
        #expect(!first.isError)
        let action = try #require(f.rules.ruleActions.first)
        let duplicate = await f.runtime.callTool("zeus_rule_shadow", arguments: request(), sessionKey: session)
        #expect(!duplicate.isError && duplicate.structured?["action_id"] == .string(action.id))
        for changed in [request("Buy ink"), request(amount: 45), request(currency: "EUR")] {
            let result = await f.runtime.callTool("zeus_rule_shadow", arguments: changed, sessionKey: session)
            #expect(result.isError && result.text.contains(action.id) && result.text.contains("approve or decline"))
        }
        for invalid in [request(amount: "fourteen"), request(amount: 0), request(currency: "usd")] {
            let result = await f.runtime.callTool("zeus_rule_shadow", arguments: invalid, sessionKey: session)
            #expect(result.isError && !result.text.contains("still waiting"))
        }
        let other = "claude:/fixture#456.1"
        f.runtime.registerSession(.init(id: UUID(), sessionKey: other, agent: .claude, cwd: "/fixture", clientName: "Other", supportsChannel: true, tmuxPane: nil, connectedAt: f.clock.now))
        let crossSession = await f.runtime.callTool("zeus_rule_shadow", arguments: request(), sessionKey: other)
        #expect(crossSession.isError && crossSession.text.contains(action.id))
        #expect(f.rules.ruleActions.count == 1)
        let reopened = try PersistentRulesStore(fileURL: f.root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        #expect(reopened.ruleActions.first?.requestFingerprint == action.requestFingerprint)
        let cardID = try #require(action.approvalCardID)
        f.cards.respond(id: cardID, option: "approve", label: "Approve this purchase")
        let wrong: JSONValue = ["ruleID": .string(rule.id), "did": "Buy ink", "approvalID": .string(action.id)]
        #expect(await f.runtime.callTool("zeus_rule_acted", arguments: wrong, sessionKey: session).isError)
        let exact: JSONValue = ["ruleID": .string(rule.id), "did": "Buy paper", "approvalID": .string(action.id)]
        #expect(!(await f.runtime.callTool("zeus_rule_acted", arguments: exact, sessionKey: session)).isError)
        #expect(await f.runtime.callTool("zeus_rule_acted", arguments: exact, sessionKey: session).isError)
    }

    @Test func redactedDescriptionsCannotMakeDifferentPurchasesLookIdentical() async throws {
        let f = try LearningRuntimeFixture(redactor: PurchaseFixtureRedactor()); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Buy supplies", trigger: .init(kind: "spend"), kind: .acts)], at: f.clock.now).first)
        for (index, text) in ["Buy paper for Alex", "Buy paper for Blair"].enumerated() {
            let result = await f.runtime.callTool("zeus_rule_shadow", arguments: ["ruleID": .string(rule.id), "wouldHave": .string(text), "amount": 14, "currency": "USD"], sessionKey: session)
            #expect(result.isError == (index == 1))
        }
        #expect(f.rules.ruleActions.count == 1)
        #expect(f.rules.ruleActions.first?.text == "Buy paper for ‹name›")
    }

    @Test func legacyPurchaseCannotClaimExactReplayWithoutFingerprint() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Buy supplies", trigger: .init(kind: "spend"), kind: .acts)], at: f.clock.now).first)
        let legacy = RuleActionRecord(id: "legacy", ruleID: rule.id, sessionKey: session, text: "Buy paper", created: f.clock.now, kind: .shadow, amount: 14, currency: "USD")
        let decoded = try ZeusJSON.decoder().decode(RuleActionRecord.self, from: ZeusJSON.encoder().encode(legacy))
        #expect(decoded.requestFingerprint == nil)
        try f.rules.recordAction(decoded)
        let result = await f.runtime.callTool("zeus_rule_shadow", arguments: ["ruleID": .string(rule.id), "wouldHave": "Buy paper", "amount": 14, "currency": "USD"], sessionKey: session)
        #expect(result.isError && result.text.contains("legacy"))
        #expect(f.rules.ruleActions.count == 1)
    }

    @Test(arguments: [
        ("2026-10-26T00:00:00-05:00", "2026-11-02T00:00:00-06:00"),
        ("2026-03-02T00:00:00-06:00", "2026-03-09T00:00:00-05:00")
    ])
    func journalUsesSevenLocalCalendarDaysAcrossDST(range: (String, String)) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let f = try LearningRuntimeFixture(calendar: calendar); defer { f.stop() }
        let formatter = ISO8601DateFormatter()
        let from = try #require(formatter.date(from: range.0)), to = try #require(formatter.date(from: range.1))
        f.clock.now = to
        let result = await f.runtime.callTool("zeus_get_journal", arguments: ["from": .string(range.0), "to": .string(range.1)], sessionKey: session)
        #expect(!result.isError)
        #expect(result.structured?["from"] == .string(from.ISO8601Format()))
        let tooEarly = await f.runtime.callTool("zeus_get_journal", arguments: ["from": .string(from.addingTimeInterval(-1).ISO8601Format()), "to": .string(range.1)], sessionKey: session)
        #expect(tooEarly.isError && tooEarly.text.contains(range.0))
        let reversed = await f.runtime.callTool("zeus_get_journal", arguments: ["from": .string(range.1), "to": .string(range.0)], sessionKey: session)
        #expect(reversed.isError && reversed.text.contains("from must not be later than to"))
        let defaultFrom = await f.runtime.callTool("zeus_get_journal", arguments: ["to": .string(range.1)], sessionKey: session)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: to))
        #expect(defaultFrom.structured?["from"] == .string(yesterday.ISO8601Format()))
    }

    @Test func misspelledNestedOptionKeyCannotSilentlyLoseDestructiveStyle() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let result = await f.call("zeus_ask", ["text": "Delete the draft?", "wait_seconds": 0,
            "options": [["id": "delete", "label": "Delete", "styles": "destructive"]]])
        #expect(result.isError && result.text.contains("options[0]") && result.text.contains("styles"))
        #expect(f.cards.values.isEmpty)
        let valid = await f.call("zeus_ask", ["text": "Delete the draft?", "wait_seconds": 0,
            "options": [["id": "delete", "label": "Delete", "style": "destructive"]]])
        #expect(!valid.isError && f.cards.values.last?.options.first?.style == .destructive)
    }
}

private struct PurchaseFixtureRedactor: Redactor {
    func redact(_ text: String) async -> Redacted<String> {
        .init(text.replacingOccurrences(of: "Alex", with: "‹name›").replacingOccurrences(of: "Blair", with: "‹name›"))
    }
}
