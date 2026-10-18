import AppKit
import Testing
import ZeusDesign
@testable import Zeus

@MainActor struct UX4LearningLineTests {
    @Test func longViewCountsWrappedLinesAndKeepsShortNotesInline() {
        ZeusFonts.registerBundled()
        for choice in ZeusFontChoice.allCases {
            #expect(!ConversationNoticeLine.needsDocument("A short note.", width: 300, choice: choice, scale: .default))
            #expect(ConversationNoticeLine.needsDocument(String(repeating: "A long reflection paragraph. ", count: 100),
                                                         width: 300, choice: choice, scale: .default))
            #expect(ConversationNoticeLine.needsDocument(Array(repeating: "Line", count: 20).joined(separator: "\n"),
                                                         width: 300, choice: choice, scale: .default))
        }
    }
    @Test func receiptsOutrankDiscardedAndUnknownDisappearanceDoesNotInventSent() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.controller.pendingLearningDeliveries = [.init(id: "old", kind: .reflection, text: "exact", preparedAt: f.now, sessionLabel: "Fixture")]
        f.deliveries.reconcile()
        f.controller.pendingLearningDeliveries = []
        f.deliveries.reconcile()
        #expect(f.cards.notices.first?.summary == "Evening reflection ready for your assistant")
        f.controller.discardedLearningDeliveries = [.init(id: "old", kind: .reflection, text: "exact", preparedAt: f.now,
            discardedAt: f.now, reason: .expired, queueReason: "Not sent", deliveryKindName: "Evening reflection")]
        f.deliveries.reconcile()
        #expect(f.cards.notices.first?.summary == "Not sent" && f.deliveries.discarded.count == 1)
        f.cards.updateNotice(id: "n_old") { $0.summary = "Sent the evening reflection" }
        f.deliveries.receivedDeliveryIDs = { ["old"] }; f.deliveries.reconcile()
        #expect(f.deliveries.discarded.isEmpty && f.cards.notices.first?.summary == "Sent the evening reflection")
    }

    @Test func ledgerHasNotSentRowsAndNeverShowsEmptyCaptionForThem() throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.controller.discardedLearningDeliveries = [.init(id: "old", kind: .brief, text: "Exact old request", preparedAt: f.now,
            discardedAt: f.now, reason: .superseded, queueReason: "Replaced by today's brief request", deliveryKindName: "Morning brief request")]
        f.deliveries.reconcile()
        let viewer = JournalViewerModel(journal: LM2JournalFake(), now: f.now)
        viewer.deliveries = f.deliveries; viewer.sentOnly = true
        #expect(viewer.notSent.count == 1 && !viewer.emptyCaption.contains("Nothing yet"))
        viewer.search = "Replaced"; #expect(viewer.notSent.count == 1)
        viewer.search = "unrelated"; #expect(viewer.notSent.isEmpty && viewer.emptyCaption == "Nothing matches.")
        for kind in ["digest", "reflection", "brief", "moment", "ruleTrigger", "rating"] {
            let item = JournalItem(time: f.now, level: .activity, kind: .sentToAssistant,
                payload: .init(.init(description: "Receipt sentence", text: "Exact", details: ["kind": kind])))
            #expect(JournalDisplay.ledgerTitle(item) == LearningDeliveryVocabulary.title(kind: kind))
        }
    }

    @Test func persistedLegacyNoticeUsesTheSameReadingVocabulary() {
        for (summary, title) in [("Daily reflection ready", "Evening reflection"),
                                 ("Sent your daily summary", "Morning summary"),
                                 ("Replaced by today's brief request", "Morning brief request"),
                                 ("Sent a rule trigger: dinner", "Rule trigger"),
                                 ("Sent your message preference", "Message preference"),
                                 ("Note ready: focused work", "Note")] {
            let notice = ThreadNotice(kind: .learning, createdAt: Date(), summary: summary, detail: "exact")
            #expect(notice.learningDocumentKind == title)
            #expect(notice.learningDocumentTitle.hasPrefix(title + " · "))
            #expect(notice.summary == summary && notice.detail == "exact")
        }
    }
}
