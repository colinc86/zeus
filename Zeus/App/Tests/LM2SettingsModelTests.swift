import Foundation
import Observation
import Testing
@testable import Zeus

@MainActor @Observable final class LM2JournalFake: JournalStore {
    var revision: UInt64 = 0
    var lastError: String?
    var records: [JournalItem] = []
    var fails = false
    private struct Failure: Error {}
    func append(_ item: JournalItem) throws { if fails { throw Failure() }; records.append(item); revision += 1 }
    func items(matching q: JournalQuery) throws -> [JournalItem] {
        if fails { throw Failure() }
        return Array(records.filter { item in
            (q.from.map { item.time >= $0 } ?? true) && (q.to.map { item.time < $0 } ?? true)
            && (q.levels.isEmpty || q.levels.contains(item.level)) && (q.apps.isEmpty || q.apps.contains(item.app ?? ""))
            && (q.kinds.isEmpty || q.kinds.contains(item.kind))
        }.prefix(q.limit))
    }
    func delete(_ selection: JournalDeletion) throws {
        if fails { throw Failure() }
        records.removeAll { item in
            switch selection {
            case .all: true
            case .item(let id): item.id == id
            case .app(let app): item.app == app
            case .day(let date): Calendar.current.isDate(date, inSameDayAs: item.time)
            }
        }; revision += 1
    }
    func export(matching query: JournalQuery) throws -> Data { try JSONEncoder().encode(items(matching: query)) }
    func prune(retention: JournalRetention, now: Date) throws {}
}
@MainActor @Observable final class LM2RulesFake: RulesStore {
    var rules: [LearnedRule] = []
    var revision: UInt64 = 0
    var lastError: String?
    var autonomy: Double = 0.5
    var outcomes: [RuleOutcome] = []
    func propose(_ proposals: [RuleProposal], at now: Date) throws -> [LearnedRule] {
        let new = proposals.map { LearnedRule(id: UUID().uuidString, sentence: $0.sentence, trigger: $0.trigger, kind: $0.kind,
            status: $0.kind == .acts ? .shadow : .active, confidence: $0.confidence, evidence: $0.evidence, created: now, updated: now, updatedBy: .agent) }
        rules += new; revision += 1; return new
    }
    func addOwn(_ proposal: RuleProposal, at now: Date) throws -> LearnedRule {
        var proposal = proposal; proposal.kind = .passive
        var rule = try propose([proposal], at: now)[0]; rule.updatedBy = .user
        rules[rules.count - 1] = rule; return rule
    }
    func restoreDeleted(_ rule: LearnedRule) throws { rules.append(rule); revision += 1 }
    func setStatus(_ status: LearnedRuleStatus, id: String, at now: Date) throws { if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].status = status; revision += 1 } }
    func edit(id: String, sentence: String, trigger: RuleTrigger, at now: Date) throws {
        if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].sentence = sentence; rules[i].trigger = trigger; rules[i].updatedBy = .user; revision += 1 }
    }
    func delete(id: String) throws { rules.removeAll { $0.id == id }; revision += 1 }
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], at now: Date) throws { outcomes.append(outcome) }
}

@MainActor struct LM2SettingsModelTests {
    @Test func viewerFiltersExactStoredRedactionsAndExportsSelection() throws {
        let store = LM2JournalFake(), now = Date()
        let payload = Redacted(JournalPayload(description: "Review for ‹email›", text: "Secret: ‹secret›", details: ["document": "file:///project/Example.swift"]))
        store.records = [JournalItem(id: "focus", time: now, level: .focus, app: "test.editor", kind: .focus, payload: payload),
                         JournalItem(id: "sent", time: now, level: .activity, app: "test.editor", kind: .sentToAssistant, payload: payload),
                         JournalItem(id: "yesterday", time: now.addingTimeInterval(-86400), level: .focus, app: "test.other", kind: .focus, payload: payload)]
        let viewer = JournalViewerModel(journal: store, now: now)
        #expect(viewer.items.count == 1)
        viewer.level = 2; #expect(viewer.items.map(\.id) == ["focus"])
        #expect(viewer.items[0].payload == payload)
        let exported = try JSONDecoder().decode([JournalItem].self, from: #require(viewer.export()))
        #expect(exported == viewer.items)
        viewer.level = 0; viewer.sentOnly = true; #expect(viewer.items.map(\.id) == ["sent"])
        viewer.app = "test.other"; #expect(viewer.items.isEmpty)
        #expect(viewer.evidence(ids: ["yesterday"]).map(\.id) == ["yesterday"])
    }
    @Test func deletionInvalidatesCaptureAndFailedWriteDoesNotPretendSuccess() throws {
        let store = LM2JournalFake(), viewer = JournalViewerModel(journal: LM2JournalFake())
        let actual = JournalViewerModel(journal: store)
        var invalidations = 0; actual.beforeDelete = { invalidations += 1 }
        store.records = [JournalItem(level: .focus, app: "test.editor", kind: .focus, payload: Redacted(JournalPayload(description: "Safe")))]
        actual.reload(); store.fails = true
        #expect(!actual.delete(.all)); #expect(actual.error != nil); #expect(store.records.count == 1)
        store.fails = false; #expect(actual.delete(.all)); #expect(actual.items.isEmpty)
        #expect(invalidations == 2); #expect(viewer.items.isEmpty)
    }
    @Test func ruleCreationEditingApprovalAndEvidenceRemainScoped() throws {
        let store = LM2RulesFake(), journal = LM2JournalFake(), model = RulesPaneModel(store: LM2RulesFake(), journal: JournalViewerModel(journal: LM2JournalFake()))
        let actual = RulesPaneModel(store: store, journal: JournalViewerModel(journal: journal))
        actual.sentence = "Prepare a draft"; actual.kind = .acts; actual.startMinute = "18:00"; actual.endMinute = "09:00"
        actual.appIDs = "test.editor, test.browser"; #expect(actual.save())
        var rule = try #require(store.rules.first)
        #expect(rule.status == .active); #expect(rule.updatedBy == .user); #expect(rule.trigger.time?.startMinute == 1080)
        #expect(RulesPaneModel.triggerText(rule.trigger).contains("18:00–09:00"))
        actual.approve(rule); #expect(store.rules[0].status == .active); #expect(store.outcomes.isEmpty)
        rule = store.rules[0]; actual.beginEdit(rule); actual.sentence = "Prepare a careful draft"; #expect(actual.save())
        #expect(store.rules.count == 1); #expect(store.rules[0].id == rule.id); #expect(store.rules[0].evidence == rule.evidence)
        actual.setEnabled(false, rule: rule); #expect(store.rules[0].status == .retired)
        actual.delete(rule); #expect(store.rules.isEmpty); #expect(model.rules.isEmpty)
    }
    @Test func invalidRulesNeverReachStoreAndMissingEvidenceIsEmpty() throws {
        let store = LM2RulesFake(), model = RulesPaneModel(store: LM2RulesFake(), journal: JournalViewerModel(journal: LM2JournalFake()))
        #expect(!model.save()); model.sentence = "Wait"; model.startMinute = "25:00"; model.endMinute = "08:00"
        #expect(!model.save()); #expect(model.error?.contains("HH:mm") == true)
        #expect(store.rules.isEmpty); #expect(model.journal.evidence(ids: ["deleted"]).isEmpty)
    }
}
