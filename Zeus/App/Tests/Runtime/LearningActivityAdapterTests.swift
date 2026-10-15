import Foundation
import Testing
@testable import Zeus

private actor PausedLearningRedactor: Redactor {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func redact(_ text: String) async -> Redacted<String> {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return .init("redacted")
    }
    func release() { continuation?.resume(); continuation = nil }
}
@Suite @MainActor struct LearningActivityAdapterTests {
    @Test func legacyMigrationRedactsBeforeJournalAndRemovesSourceAfterCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2_l1_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ActivityStore(root: root.appendingPathComponent("Activity")), now = Date()
        try old.append(.init(t: now, kind: .activate, app: "com.example.Editor", name: "private@example.test"))
        let journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: FixtureJournalKey())
        let adapter = ActivityStore(root: old.root, journal: journal)
        try await adapter.migrateLegacy(redactor: LocalRedactor(useOnDeviceModel: false), allowed: { _ in true }, stillAllowed: { true })
        #expect(!FileManager.default.fileExists(atPath: old.fileURL(for: now).path))
        #expect(try journal.items(matching: .init()).count == 1)
        #expect(adapter.events(on: now).first?.name == "‹email›")
        try await adapter.migrateLegacy(redactor: LocalRedactor(useOnDeviceModel: false), allowed: { _ in true }, stillAllowed: { true })
        #expect(try journal.items(matching: .init()).count == 1)
        #expect(throws: LearningStorageError.self) { try adapter.append(.init(t: now, kind: .active)) }
    }
    @Test func disableOrDeletionDuringRedactionCannotAppend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2_l1_" + UUID().uuidString)
        let suite = "lm2-l1-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = LearnSettings(defaults: defaults); settings.enabled = true
        let journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: FixtureJournalKey())
        let redactor = PausedLearningRedactor()
        let learn = LearnFromMe(settings: settings, root: root.appendingPathComponent("Activity"), journal: journal, redactor: redactor)
        learn.record(.init(t: Date(), kind: .active))
        for _ in 0..<1000 { if await redactor.entered { break }; await Task.yield() }
        #expect(await redactor.entered)
        settings.enabled = false; learn.invalidatePendingCapture(); try journal.delete(.all)
        await redactor.release()
        for _ in 0..<30 { await Task.yield() }
        #expect(try journal.items(matching: .init()).isEmpty)
        learn.stop()
    }
}
