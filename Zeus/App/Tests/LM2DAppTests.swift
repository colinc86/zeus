import Foundation
import Testing
@testable import Zeus

@MainActor struct LM2DAppTests {
    @Test func rawConsentIsIndependentCancelSafeDurableAndRevocable() throws {
        let name = "zeus-depth-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ObservationSettings(defaults: defaults)
        let consent = RawJournalConsentModel(settings: settings, level: .screen)
        #expect(!settings.rawAllowed(3)); consent.setEnabled(true)
        #expect(consent.showsConsent && !settings.rawAllowed(3))
        consent.cancel(); consent.allow(); #expect(!settings.rawAllowed(3))
        consent.setEnabled(true); consent.allow()
        #expect(ObservationSettings(defaults: defaults).rawAllowed(3))
        #expect(!settings.rawAllowed(4)); #expect(!settings.policy(3).enabled)
        consent.setEnabled(false); #expect(!ObservationSettings(defaults: defaults).rawAllowed(3))
        settings.setRawAllowed(true, level: 2); #expect(!settings.rawAllowed(2))
    }
    @Test func journalPolicyFollowsEnabledConsentedLevelsWithoutRetiredRawGrant() throws {
        let name = "zeus-depth-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil)
        let model = LearningPresentation(defaults: defaults, learn: learn)
        defer { model.stop() }
        #expect(model.journalAccessPolicy == .init())
        model.policies.setRawAllowed(true, level: 3)
        model.policies.edit(3) { $0.enabled = true }
        #expect(model.journalAccessPolicy.rawLevels.isEmpty)
        model.policies.edit(3) { $0.consented = true }
        #expect(model.journalAccessPolicy.enabledLevels == [.screen])
        #expect(model.journalAccessPolicy.rawLevels == [.screen])
        model.policies.setRawAllowed(false, level: 3)
        #expect(model.journalAccessPolicy.rawLevels == [.screen])
        model.policies.edit(3) { $0.enabled = false }
        #expect(model.journalAccessPolicy.enabledLevels.isEmpty)
    }
    @Test func exactLedgerNavigationClearsFiltersAndUsesAnswerDay() throws {
        let journal = LM2JournalFake(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let answer = Self.answer(time: now)
        journal.records = [answer]
        let model = JournalViewerModel(journal: journal, now: now.addingTimeInterval(86_400))
        model.level = 4; model.app = "other"; model.search = "unrelated"
        model.showAnswer(id: answer.id)
        #expect(model.sentOnly && model.level == 0 && model.app.isEmpty && model.search.isEmpty)
        #expect(model.selectedAnswerID == answer.id && model.items == [answer])
        #expect(model.items.first?.payload.value.text == answer.payload.value.text)
        #expect(JournalDisplay.ledgerTitle(answer) == "Journal answer")
        #expect(JournalAnswerDisplay.size(answer) == "1 item")
        #expect(JournalAnswerDisplay.rawCaption(answer) == "Includes your words")
        let decoded = try #require(JournalAnswerPayload.decode(answer))
        #expect(decoded.items.first?.words == "hello ‹name›")
        model.showAnswer(id: "missing"); #expect(model.error != nil)
    }
    @Test func rawRefusalIsDistinctFromSentWordsOrPictures() {
        var answer = Self.answer(time: Date())
        answer = JournalItem(id: answer.id, time: answer.time, level: answer.level, kind: answer.kind,
            payload: .init(.init(description: "Journal answer", details: ["kind": "journal_answer", "raw_screen": "not allowed", "raw_typing": "not allowed"])))
        #expect(JournalAnswerDisplay.rawCaption(answer) == "Asked for pictures; not allowed · Asked for words; not allowed")
        #expect(JournalAnswerPayload.decode(answer) == nil)
    }
    @Test func twoActionLearningNoticePersistsQuietlyAndResolvesThroughExistingMechanism() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CardStore(fileURL: file); let recorder: any LearningNoticeRecording = store
        var approved = 0, declined = 0
        let notice = LearningNotice(id: "shadow", kind: .shadow, createdAt: Date(timeIntervalSince1970: 1_800_000_000), summary: "I'd have sent an update", actionTitle: "OK next time?", detail: "Your rule: Send an update", ruleID: "rule")
        let recorded = recorder.recordLearningNotice(notice, action: { approved += 1 }, secondaryTitle: "Not this", secondary: { declined += 1 })
        #expect(recorded)
        #expect(store.unseenCount == 0 && store.cards.isEmpty)
        #expect(store.notices.first?.detail == nil && store.notices.first?.help == notice.detail)
        #expect(store.hasNoticeAction(id: notice.id) && store.hasSecondaryNoticeAction(id: notice.id))
        store.performSecondaryNoticeAction(id: notice.id); store.performNoticeAction(id: notice.id)
        #expect(declined == 1 && approved == 0)
        let resolved = LearningNotice(id: notice.id, kind: .shadow, createdAt: notice.createdAt, summary: "Got it. I won't.", actionTitle: nil, detail: nil, ruleID: "rule")
        #expect(recorder.recordLearningNotice(resolved, action: nil, secondaryTitle: nil, secondary: nil))
        #expect(store.notices.count == 1 && store.notices.first?.summary == resolved.summary)
        #expect(!store.hasSecondaryNoticeAction(id: notice.id))
        #expect(CardStore(fileURL: file).notices == store.notices)
    }
    @Test func failedNoticePersistenceNeverRunsEitherAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("depth-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json"), store = CardStore(fileURL: root.appendingPathComponent("history.json"))
        var count = 0
        let notice = LearningNotice(id: "shadow", kind: .shadow, createdAt: Date(timeIntervalSince1970: 1_800_000_000), summary: "Shadow", actionTitle: "OK", detail: nil, ruleID: nil)
        let recorded = store.recordLearningNotice(notice, action: { count += 1 }, secondaryTitle: "Not this", secondary: { count += 1 })
        #expect(recorded)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        store.performNoticeAction(id: notice.id); store.performSecondaryNoticeAction(id: notice.id)
        #expect(count == 0 && store.hasNoticeAction(id: notice.id) && store.hasSecondaryNoticeAction(id: notice.id))
    }
    @Test func everyQuietLineRunsItsActionAndNavigationRemainsReusable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("depth-actions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CardStore(fileURL: file)
        for (index, title) in ["View", "OK next time?", "Undo", "Not again", "Review"].enumerated() {
            var count = 0
            let notice = LearningNotice(id: "n-\(index)", kind: .reflection, createdAt: Date(), summary: "Quiet line", actionTitle: title, detail: nil, ruleID: nil)
            let recorded = store.recordLearningNotice(notice, action: { count += 1 })
            #expect(recorded)
            store.performNoticeAction(id: notice.id); store.performNoticeAction(id: notice.id)
            #expect(count == (["View", "Review"].contains(title) ? 2 : 1))
        }
        #expect(store.unseenCount == 0 && store.cards.isEmpty)
    }
    @Test func runtimeReadStateUsesDurableSeenIDs() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("depth-read-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CardStore(fileURL: file)
        let readState: any LearningCardReadState = store
        store.add(.init(id: "produced", kind: .message, body: "Prepared a list"))
        #expect(!readState.learningCardWasRead(id: "produced"))
        store.markSeen(id: "produced")
        #expect(readState.learningCardWasRead(id: "produced"))
        #expect(!readState.learningCardWasRead(id: "other"))
        #expect(CardStore(fileURL: file).learningCardWasRead(id: "produced"))
    }
    static func answer(time: Date) -> JournalItem {
        .init(id: "journal_answer_fixture", time: time, level: .typed, kind: .sentToAssistant,
            payload: .init(.init(description: "Journal answer", text: #"{"items":[{"id":"typing","time":"2026-10-15T14:00:00Z","kind":"typing","text":"Writing a note","words":"hello ‹name›"}]}"#,
                details: ["kind": "journal_answer", "item_count": "1", "includes_words": "true", "sessionLabel": "Claude · Zeus", "range": "Thu 14:00–15:30"])))
    }
}
