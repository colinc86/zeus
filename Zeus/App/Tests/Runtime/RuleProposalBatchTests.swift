import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@Suite @MainActor struct RuleProposalBatchTests {
    let session = "claude:/fixture#123.1"
    func fixture() throws -> LearningRuntimeFixture {
        let f = try LearningRuntimeFixture()
        try f.allowProposals()
        try f.journal.append(.init(id: "day3", time: f.clock.now.addingTimeInterval(-2 * 86400), level: .activity,
            app: "com.apple.logic10", kind: .activity, payload: .init(.init(description: "Synthetic music work", details: ["name": "Logic Pro"]))))
        try f.runtime.ledger?.update(id: "fixture_reflection") { $0.meta["evidence"] = "day1,day2,day3" }
        return f
    }
    func proposal(_ trigger: JSONValue, sentence: String = "Hold routine cards during focused work") -> JSONValue {
        ["sentence": .string(sentence), "trigger": trigger, "evidence": ["day1", "day2", "day3"]]
    }
    func entries(_ response: ToolResult) throws -> [[String: JSONValue]] {
        guard case .object(let object) = response.structured, case .array(let values) = object["results"] else {
            Issue.record("Missing per-rule results: \(response.text)"); return []
        }
        return try values.map { value in
            guard case .object(let fields) = value else { throw ToolArgumentError("Expected result object") }
            return fields
        }
    }
    @Test func exactDogfoodBatchAcceptsBothAndStoresBundleID() async throws {
        let f = try fixture(); defer { f.stop() }
        let response = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [
            proposal(["time": ["startMinute": 0, "endMinute": 465]], sentence: "Hold routine digest cards before about 07:45; send them once the day has started."),
            proposal(["apps": ["Logic Pro"]], sentence: "Hold routine, non-urgent cards while Logic Pro is in front; deliver them after switching away.")]], sessionKey: session)
        let rows = try entries(response)
        #expect(!response.isError && rows.count == 2)
        #expect(rows.map { $0["result"] } == ["accepted", "accepted"])
        #expect(rows.map { $0["index"] } == [1, 2])
        #expect(f.rules.rules.last?.trigger.apps == ["com.apple.logic10"])
        #expect(f.rules.rules.first?.trigger.time?.endMinute == 465)
        #expect(f.rules.ruleNoticeGroups().count == 1)
    }
    @Test func typoRejectsOnlyItsRuleAndDoesNotSpendDailyAllowance() async throws {
        let f = try fixture(); defer { f.stop() }
        let response = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [
            proposal(["time": ["startMinute": 0, "endMinute": 465]]), proposal(["apps": ["Lgic Pro"]])]], sessionKey: session)
        let rows = try entries(response)
        #expect(!response.isError && rows[0]["result"] == "accepted" && rows[1]["result"] == "rejected")
        #expect(response.text.contains("rule 2: trigger.apps") && response.text.contains("Lgic Pro"))
        #expect(f.rules.rules.count == 1)
        let next = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [proposal([:]), proposal([:]), proposal([:])]], sessionKey: session)
        let nextRows = try entries(next)
        #expect(!next.isError && nextRows.map { $0["result"] } == ["accepted", "accepted", "rejected"])
        #expect(next.text.contains("rule 3:") && next.text.contains("three new rules per day"))
        #expect(f.rules.rules.count == 3)
    }
    @Test func fieldErrorsHaveRuleIndexAndFixHint() async throws {
        let f = try fixture(); defer { f.stop() }
        let bad: [(JSONValue, String)] = [
            (proposal(["time": ["startMinute": -1, "endMinute": 465]]), "trigger.time"),
            (proposal(["time": ["startMinute": 0, "endMinute": 465, "weekdays": [0]]]), "weekdays"),
            (["sentence": "Quiet", "evidence": ["day1", "day1"]], "duplicate"),
            (["sentence": "Quiet", "evidence": [""]], "nonempty"),
            (["sentence": "Quiet", "evidence": ["invented"]], "Invalid IDs: invented"),
            (["sentence": "Quiet", "confidence": 0.99], "confidence"),
            (["sentence": ""], "sentence"),
            (proposal(["time": ["startMinute": "midnight", "endMinute": 465]]), "trigger.time.startMinute")
        ]
        for (value, field) in bad {
            let response = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": .array([value])], sessionKey: session)
            #expect(response.isError)
            #expect(response.text.contains("rule 1:") && response.text.contains(field))
            #expect(try entries(response).first?["result"] == "rejected")
        }
        #expect(f.rules.rules.isEmpty)
    }
    @Test func suppressionRejectsOnlyMatchingRule() async throws {
        let f = try fixture(); defer { f.stop() }
        _ = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [proposal(["apps": ["Logic Pro"]])]], sessionKey: session)
        let rule = try #require(f.rules.rules.first)
        try f.rules.setStatus(.proposed, id: rule.id, at: f.clock.now)
        let response = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [proposal(["apps": ["logic pro"]]), proposal([:])]], sessionKey: session)
        #expect(!response.isError)
        #expect(try entries(response).map { $0["result"] } == ["rejected", "accepted"])
        #expect(response.text.contains("rule 1:") && response.text.contains("30 days"))
    }
    @Test func resolutionUsesObservedNamesFirstAndRejectsAmbiguity() throws {
        let rows = [JournalItem(level: .activity, app: "com.example.music", kind: .activity,
            payload: .init(.init(description: "Synthetic", details: ["name": "Music App"])))]
        #expect(try RuleAppResolver.resolve(["mUsIc ApP"], observed: rows, installed: { _ in Issue.record("Observed name should win"); return [] }) == ["com.example.music"])
        #expect(try RuleAppResolver.resolve(["Installed App"], observed: [], installed: { _ in ["com.example.installed"] }) == ["com.example.installed"])
        #expect(try RuleAppResolver.resolve(["com.example.direct"], observed: [], installed: { _ in [] }) == ["com.example.direct"])
        let ambiguous = rows + [.init(level: .activity, app: "com.example.other", kind: .activity, payload: .init(.init(description: "Synthetic", details: ["name": "Music App"])))]
        do {
            _ = try RuleAppResolver.resolve(["Music App"], observed: ambiguous, installed: { _ in [] })
            Issue.record("Ambiguous observed name must be rejected")
        } catch { #expect(error.localizedDescription.contains("more than one app") && error.localizedDescription.contains("bundle ID")) }
    }
}
