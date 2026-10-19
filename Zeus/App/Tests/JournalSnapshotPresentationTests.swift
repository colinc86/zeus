import Foundation
import Observation
import Testing
@testable import Zeus

@MainActor struct JournalSnapshotPresentationTests {
    @Test func filtersDuringLoadUseLatestSelectionAndNeverRescanLoadedData() async {
        let source = SnapshotPresentationJournal(), now = Date()
        source.records = [item("today", at: now), item("yesterday", at: now.addingTimeInterval(-86400))]
        let model = JournalViewerModel(journal: source, now: now)
        #expect(model.isLoading && model.items.isEmpty)
        await source.requested()
        model.day = now.addingTimeInterval(-86400); model.level = 2; model.app = "test.editor"; model.search = "yesterday"
        source.finish()
        await model.waitForLoad()
        #expect(!model.isLoading)
        #expect(model.items.map(\.id) == ["yesterday"])
        for value in ["", "y", "yes", "yesterday"] { model.search = value }
        #expect(source.scans == 1)
        #expect(source.synchronousReads == 0)
    }

    @Test func erasedSnapshotCannotPublishAndFailureClearsOldData() async {
        let source = SnapshotPresentationJournal(), now = Date()
        source.records = [item("forgotten", at: now)]
        let model = JournalViewerModel(journal: source, now: now)
        await source.requested()
        source.records = []; source.revision += 1
        source.finish()
        await source.requested()
        #expect(model.items.isEmpty)
        source.finish()
        await model.waitForLoad()
        #expect(model.items.isEmpty && !model.isLoading)
        source.records = [item("kept", at: now)]; source.revision += 1
        model.reload(); await source.requested(); source.finish(); await model.waitForLoad()
        #expect(model.items.count == 1)
        model.reload(); await source.requested(); source.fail(); await model.waitForLoad()
        #expect(model.items.isEmpty && model.timeline.isEmpty)
        #expect(model.error != nil && !model.isLoading)
    }

    @Test func answerNavigationWaitsUntilItsRowsExist() async {
        let source = SnapshotPresentationJournal(), now = Date()
        source.records = [.init(id: "answer", time: now.addingTimeInterval(-86400), level: .activity, kind: .sentToAssistant,
            payload: .init(.init(description: "Sent a note", text: "Exact received text")))]
        let model = JournalViewerModel(journal: source, now: now)
        model.showAnswer(id: "answer")
        #expect(model.answerSelectionRevision == 0)
        await source.requested(); source.finish(); await model.waitForLoad()
        #expect(model.items.map(\.id) == ["answer"])
        #expect(model.sentOnly && model.selectedAnswerID == "answer" && model.answerSelectionRevision == 1)
    }

    private func item(_ id: String, at time: Date) -> JournalItem {
        .init(id: id, time: time, level: .focus, app: "test.editor", kind: .focus, payload: .init(.init(description: id)))
    }
}

@MainActor private final class SnapshotPresentationJournal: JournalSnapshotProviding {
    var revision: UInt64 = 0
    var lastError: String? { nil }
    var records: [JournalItem] = []
    var scans = 0
    var synchronousReads = 0
    private var pending: CheckedContinuation<JournalSnapshot, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var captured: JournalSnapshot?
    func journalSnapshot() async throws -> JournalSnapshot {
        scans += 1
        captured = .init(revision: revision, items: records, expiresAt: nil)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation; waiter?.resume(); waiter = nil
        }
    }
    func requested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        guard let pending, let captured else { return }
        self.pending = nil; self.captured = nil; pending.resume(returning: captured)
    }
    func fail() {
        let pending = pending; self.pending = nil; captured = nil
        pending?.resume(throwing: LearningStorageError.keyUnavailable)
    }
    func items(matching query: JournalQuery) throws -> [JournalItem] { synchronousReads += 1; return records }
    func append(_ item: JournalItem) throws { records.append(item); revision += 1 }
    func delete(_ selection: JournalDeletion) throws { records = []; revision += 1 }
    func export(matching query: JournalQuery) throws -> Data { try JSONEncoder().encode(records) }
    func prune(retention: JournalRetention, now: Date) throws {}
}
