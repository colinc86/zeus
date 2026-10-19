import Foundation
import Testing
@testable import Zeus

@MainActor struct JournalPictureRecoveryTests {
    @Test func unavailablePictureRecoversWithoutARevisionOrADeletion() throws {
        let store = PictureRecoveryJournal(), now = Date()
        let item = JournalItem(id: "picture", time: now, level: .screen, kind: .frame,
            payload: .init(.init(description: "Synthetic picture")))
        store.records = [item]
        let viewer = JournalViewerModel(journal: store, now: now)
        let picture = try #require(viewer.pictures.rows.first)
        store.unavailable = true
        #expect(viewer.pictures.frame(picture) == nil)
        #expect(viewer.pictures.caption(picture) == "Picture can't be shown right now.")
        #expect(viewer.pictures.error == "Couldn't read this picture. Nothing was deleted.")
        let reads = store.reads
        store.unavailable = false
        viewer.reload()
        #expect(viewer.pictures.frame(picture) == store.image)
        #expect(store.reads > reads)
        #expect(viewer.pictures.error == nil)
        #expect(viewer.pictures.caption(picture).hasPrefix("Picture ·"))
        #expect(store.revision == 0)
        #expect(store.deletions == 0)
    }

    @Test func missingFileIsNotAUserDeletionAndExplicitReloadRetries() throws {
        let store = PictureRecoveryJournal(), now = Date()
        store.records = [.init(id: "picture", time: now, level: .screen, kind: .frame,
            payload: .init(.init(description: "Synthetic picture")))]
        store.hasFile = false
        let viewer = JournalViewerModel(journal: store, now: now)
        let picture = try #require(viewer.pictures.rows.first)
        #expect(viewer.pictures.caption(picture) == "Picture missing: Zeus can't find its file.")
        #expect(viewer.pictures.error == nil)
        store.hasFile = true
        viewer.reload()
        #expect(viewer.pictures.frame(picture) == store.image)
        #expect(store.deletions == 0)
    }
}

@MainActor private final class PictureRecoveryJournal: JournalStore, FrameJournalStoring {
    let revision: UInt64 = 0
    var lastError: String? { nil }
    var records: [JournalItem] = []
    var unavailable = false
    var hasFile = true
    var reads = 0
    var deletions = 0
    let image = Redacted(FrameItem(heic: Data([0]), width: 1, height: 1, boxes: [], appName: "Fixture", windowTitle: "Synthetic"))
    func items(matching query: JournalQuery) throws -> [JournalItem] {
        records.filter { query.kinds.isEmpty || query.kinds.contains($0.kind) }
    }
    func frame(id: String) throws -> Redacted<FrameItem>? {
        reads += 1
        if unavailable { throw LearningStorageError.keyUnavailable }
        return hasFile ? image : nil
    }
    func append(_ item: JournalItem) throws { records.append(item) }
    func appendFrame(_ frame: Redacted<FrameItem>, item: JournalItem) throws { records.append(item) }
    func delete(_ selection: JournalDeletion) throws { deletions += 1 }
    func export(matching query: JournalQuery) throws -> Data { try JSONEncoder().encode(records) }
    func prune(retention: JournalRetention, now: Date) throws {}
}
