import Foundation
import Testing
@testable import Zeus

@MainActor struct LM2CTypingViewerTests {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current; return c }
    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private func run(_ id: String, app: String = "test.mail", offset: Double = 0, topic: String? = "Replying about an appointment", words: String? = "hi ‹name› here ‹pasted› thanks", reason: String = "") -> JournalItem {
        .init(id: id, time: now.addingTimeInterval(offset), level: .typed, app: app, kind: .typedText,
            payload: .init(.init(description: "Typing", text: words, topic: topic, details: ["words_not_kept": reason])))
    }
    @Test func groupingUsesAppThenCivilHourAndKeepsEachStretchIndependent() {
        let rows = [run("b", app: "test.zeta"), run("a", offset: 60), run("c", offset: -3600), run("d", offset: 120)]
        let groups = JournalTypingGroup.grouped(rows.map(JournalTypingRun.init), calendar: calendar)
        #expect(groups.count == 3); #expect(groups[0].app == "test.mail")
        #expect(groups[0].runs.map(\.id) == ["a", "d"])
        #expect(groups[1].runs.map(\.id) == ["c"]); #expect(groups[2].app == "test.zeta")
        #expect(groups[0].end.timeIntervalSince(groups[0].hour) == 3600)
        #expect(groups[0].id != groups[1].id)
    }
    @Test func pasteMarkerIsASeparateChipWithoutLosingAnyStoredText() {
        let row = JournalTypingRun(item: run("a"))
        #expect(row.segments == [.text("hi ‹name› here "), .pasted, .text(" thanks")])
        #expect(TypingWordsSegment.parse("‹pasted›‹pasted›") == [.pasted, .pasted])
        #expect(TypingWordsSegment.parse("").isEmpty)
    }
    @Test func wordsReasonsAndIMEArePresentedWithoutInternalFields() {
        #expect(JournalTypingRun(item: run("a", words: nil, reason: "setting")).missingWordsCaption == "words not kept")
        #expect(JournalTypingRun(item: run("b", words: nil, reason: "expired24Hours")).missingWordsCaption == "words deleted after 24 hours")
        #expect(JournalTypingRun(item: run("c", words: nil, reason: "expired7Days")).missingWordsCaption == "words deleted after 7 days")
        let ime = JournalTypingRun(item: run("ime", topic: nil, words: nil, reason: "inputMethod"))
        #expect(ime.topic.isEmpty); #expect(ime.missingWordsCaption.isEmpty)
    }
    @Test func encryptedViewerSearchMatchesTopicsAndWordsAndDeleteUndoRestoresOneWholeRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-typing-viewer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey(), calendar: calendar, clock: { self.now })
        try store.append(run("a")); try store.append(run("b", offset: 10, topic: "Planning a source change", words: nil))
        let viewer = JournalViewerModel(journal: store, calendar: calendar, now: now)
        viewer.level = 4; viewer.search = "appointment"
        #expect(viewer.items.map(\.id) == ["a"])
        viewer.search = "pasted"; #expect(viewer.items.map(\.id) == ["a"])
        guard case .typing(let group) = try #require(viewer.timeline.first) else { Issue.record("Expected typing group"); return }
        #expect(group.runs.count == 1)
        viewer.deleteItem(group.runs[0].item); #expect(viewer.items.isEmpty)
        viewer.undoDelete(); #expect(viewer.items.map(\.id) == ["a"])
        #expect(viewer.items[0].payload.value.topic == "Replying about an appointment")
        #expect(viewer.items[0].payload.value.text == "hi ‹name› here ‹pasted› thanks")
        viewer.search = ""; #expect(viewer.items.count == 2)
    }
    @Test func groupDeletionAndUndoOnlyAffectTheSelectedStretches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-typing-group-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey(), calendar: calendar, clock: { self.now })
        try store.append(run("a")); try store.append(run("b", offset: 10)); try store.append(run("other", app: "test.other"))
        let viewer = JournalViewerModel(journal: store, calendar: calendar, now: now)
        #expect(viewer.deleteTyping(ids: ["a", "b"]))
        #expect(viewer.items.map(\.id) == ["other"]); #expect(viewer.deletedTyping?.items.count == 2)
        viewer.undoDelete(); #expect(Set(viewer.items.map(\.id)) == ["a", "b", "other"])
        #expect(viewer.items.allSatisfy { $0.payload.value.topic != nil && $0.payload.value.text != nil })
        #expect(!viewer.deleteTyping(ids: ["a", "missing"]))
        #expect(viewer.items.count == 3); #expect(viewer.error != nil)
    }
    @Test func deletingAFilteredGroupIncludesItsHiddenStretchesButKeepsOtherAppsAndHours() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-typing-search-delete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey(), calendar: calendar, clock: { self.now })
        try store.append(run("match")); try store.append(run("hidden", offset: 10, topic: "Planning changes", words: nil))
        try store.append(run("other-app", app: "test.other")); try store.append(run("other-hour", offset: -3600))
        let viewer = JournalViewerModel(journal: store, calendar: calendar, now: now); viewer.search = "appointment"; viewer.app = "test.mail"
        let groups = viewer.timeline.compactMap { if case .typing(let group) = $0 { group } else { nil } }
        let group = try #require(groups.first { $0.runs.contains { $0.id == "match" } })
        #expect(group.runs.count == 1); #expect(group.totalCount == 2); #expect(viewer.deleteTypingGroup(group))
        #expect(Set(try store.items(matching: .init()).map(\.id)) == ["other-app", "other-hour"])
        viewer.undoDelete(); #expect(try store.items(matching: .init()).count == 4)
    }
}
