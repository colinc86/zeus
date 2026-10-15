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
}
