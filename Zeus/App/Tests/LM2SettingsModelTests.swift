import Foundation
import Observation
import Testing
@testable import Zeus

@MainActor @Observable final class LM2JournalFake: JournalStore {
    var revision: UInt64 = 0
    var lastError: String?
    var records: [JournalItem] = []
    var fails = false
    var retention: JournalRetention?
    var prunedAt: Date?
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
    func prune(retention: JournalRetention, now: Date) throws { self.retention = retention; prunedAt = now }
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
        viewer.app = "test.other"
        #expect(viewer.evidence(ids: ["yesterday"]).map(\.id) == ["yesterday"])
    }
    @Test func deletionInvalidatesCaptureAndFailedWriteDoesNotPretendSuccess() throws {
        let store = LM2JournalFake()
        let actual = JournalViewerModel(journal: store)
        var invalidations = 0; actual.beforeDelete = { invalidations += 1 }
        store.records = [JournalItem(level: .focus, app: "test.editor", kind: .focus, payload: Redacted(JournalPayload(description: "Safe")))]
        actual.reload(); store.fails = true
        #expect(!actual.delete(.all)); #expect(actual.error != nil); #expect(store.records.count == 1)
        store.fails = false; #expect(actual.delete(.all)); #expect(actual.items.isEmpty)
        #expect(invalidations == 2)
    }
    @Test func ruleCreationEditingApprovalAndEvidenceRemainScoped() throws {
        let store = LM2RulesFake(), journal = LM2JournalFake()
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
        actual.delete(rule); #expect(store.rules.isEmpty)
    }
    @Test func invalidRulesNeverReachStoreAndMissingEvidenceIsEmpty() throws {
        let store = LM2RulesFake()
        let model = RulesPaneModel(store: store, journal: JournalViewerModel(journal: LM2JournalFake()))
        #expect(!model.save()); model.sentence = "Wait"; model.startMinute = "25:00"; model.endMinute = "08:00"
        #expect(!model.save()); #expect(model.error?.contains("HH:mm") == true)
        #expect(store.rules.isEmpty); #expect(model.journal.evidence(ids: ["deleted"]).isEmpty)
    }
}

@MainActor struct LM2UndoAndNoticeTests {
    @Test func journalItemUndoIsImmediateExactAndExpiresWithoutRestoring() throws {
        let store = LM2JournalFake()
        var now = Date()
        let viewer = JournalViewerModel(journal: store, now: now, clock: { now })
        let item = JournalItem(id: "exact", time: now, level: .focus, app: "test.editor", kind: .focus,
            payload: Redacted(JournalPayload(description: "Window ‹email›"), report: .init(counts: [.email: 1])))
        try store.append(item); viewer.reload()
        viewer.deleteItem(item); #expect(store.records.isEmpty); #expect(viewer.deletedItem == item)
        viewer.undoDelete(); #expect(store.records == [item]); #expect(viewer.deletedItem == nil)
        viewer.deleteItem(item); now.addTimeInterval(6); viewer.undoDelete()
        #expect(store.records.isEmpty); #expect(viewer.deletedItem == nil)
        try store.append(item); viewer.deleteItem(item); #expect(viewer.delete(.all))
        viewer.undoDelete(); #expect(store.records.isEmpty)
    }
    @Test func ruleDeleteUndoPreservesIdentityEvidenceAndConfidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-lm2-rule-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        let model = RulesPaneModel(store: store, journal: JournalViewerModel(journal: LM2JournalFake()))
        let rule = try store.addOwn(.init(sentence: "Wait until the meeting ends", trigger: .init(state: "in a meeting")), at: Date())
        model.delete(rule); #expect(store.rules.isEmpty)
        model.undoDelete(); #expect(store.rules == [rule])
        let reopened = try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        #expect(reopened.rules == [rule])
    }
    @Test func quietNoticeReattachesAndReviewRemainsRepeatableWithoutBadge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-lm2-notice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        var reviews = 0
        let notice = LearningNotice(id: "rule:test", kind: .newRule, createdAt: Date(), summary: "New rule: Wait", actionTitle: "Review", detail: "Wait", ruleID: "test")
        let recorded = store.recordLearningNotice(notice, action: { reviews += 1 }); #expect(recorded)
        #expect(store.unseenCount == 0); #expect(store.notices.count == 1); #expect(store.notices[0].detail == nil)
        store.performNoticeAction(id: notice.id); store.performNoticeAction(id: notice.id)
        #expect(reviews == 2)
        let restored = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let reconnected = restored.recordLearningNotice(notice, action: { reviews += 1 }); #expect(reconnected); #expect(restored.notices.count == 1)
        let changed = LearningNotice(id: notice.id, kind: .shadow, createdAt: notice.createdAt, summary: "OK. I'll do that from now on.", actionTitle: "Undo", detail: nil, ruleID: "test")
        let updated = restored.recordLearningNotice(changed, action: {}); #expect(updated)
        #expect(restored.notices[0].summary == changed.summary); #expect(restored.notices[0].actionTitle == "Undo")
        #expect(restored.unseenCount == 0)
    }
    @Test func safariDetailsRequireExplicitAllowListAndPrivateListStillWins() {
        var policy = ObservationPolicy()
        policy.apps = [.init(name: "Safari", bundleIDs: ["com.apple.Safari"])]
        #expect(!policy.permitsSafariDetails)
        policy.scope = .chosenApps; #expect(policy.permitsSafariDetails)
        #expect(!policy.allows(bundleID: "com.apple.Safari", name: "Safari", privateApps: policy.apps))
        policy.apps = []; #expect(!policy.permitsSafariDetails)
        #expect(FocusRecord.documentCaption("file:///project/Example.swift") == "Example.swift — /project")
        #expect(RulesPaneModel.triggerText(.init()) == "Any time")
        #expect(SettingsView.managedConfirmationTarget(.switchConversation) == "switchConversationConfirmation")
    }
    @Test func rulesTabIsHiddenUntilEnabledAndConfidenceUsesWords() {
        let navigation = SettingsNavigation()
        #expect(!navigation.tabs.contains(.rules))
        navigation.showsRules = true; #expect(navigation.tabs.contains(.rules))
        #expect(RuleConfidence.word(0.9) == "Sure")
        #expect(RuleConfidence.word(0.6) == "Fairly sure")
        #expect(RuleConfidence.word(0.3) == "Unsure")
    }
}


private struct LM2FixtureRedactor: Redactor {
    func redact(_ text: String) async -> Redacted<String> { Redacted(text) }
}
@MainActor struct LM2PresentationTests {
    @Test func l2ContextUsesItsOwnScopeEvenWhenL1AllowListIsEmptyAndRetentionUsesEachLevel() throws {
        let suite = "zeus-lm2-presentation-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil)
        let model = LearningPresentation(defaults: defaults, learn: learn)
        let source = LM2FocusSource(), journal = LM2JournalFake()
        model.install(journal: journal, rules: LM2RulesFake(), redactor: LM2FixtureRedactor(), source: source)
        defer { model.stop() }
        #expect(!model.enabled); #expect(model.context.isPrivate)
        model.policies.edit(1) { $0.scope = .chosenApps }
        model.policies.edit(2) { $0.enabled = true; $0.consented = true; $0.retentionDays = 7 }
        #expect(model.enabled); #expect(!model.context.isPrivate)
        #expect(model.context.frontmostApp == "test.editor")
        source.idleSeconds = 10; #expect(model.context.idleSince != nil)
        #expect((model.context.idleSince?.timeIntervalSinceNow ?? 0) < -9)
        source.idleSeconds = 601; #expect(model.context.idleSince != nil)
        source.isSecure = true; #expect(model.context.isPrivate); #expect(model.context.frontmostApp == nil)
        source.isSecure = false; learn.settings.excludedApps.append(.init(name: "Editor", bundleIDs: ["test.editor"]))
        #expect(model.context.isPrivate)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.pruneExpired(now: now)
        #expect(journal.prunedAt == now); #expect(journal.retention?.activityDays == 90)
        #expect(journal.retention?.focusDays == 7); #expect(journal.retention?.frameDays == 7)
    }
}
