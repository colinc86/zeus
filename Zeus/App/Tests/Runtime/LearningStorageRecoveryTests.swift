import Foundation
import Testing
@testable import Zeus

@MainActor private final class RecoverableFixtureKey: FixtureLearningKeyProviding {
    var unavailable = false
    func key() throws -> Data {
        if unavailable { throw LearningStorageError.keyUnavailable }
        return Data(repeating: 77, count: 32)
    }
}
@Suite @MainActor struct LearningStorageRecoveryTests {
    @Test func lockedJournalQueuesOnlyInMemoryAndForgetWinsBeforeRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2_recovery_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = RecoverableFixtureKey(); key.unavailable = true
        let store = EncryptedJournalStore(root: root, keyProvider: key)
        let item = JournalItem(id: "queued", time: Date(), level: .focus, kind: .focus, payload: .init(.init(description: "Synthetic work")))
        try store.append(item); try store.append(item)
        #expect(store.pendingStorageWrites == 1 && store.storageWaitingForUnlock)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(store.lastError?.contains("memory") == true)
        key.unavailable = false; store.retryPendingWrites()
        #expect(!store.storageWaitingForUnlock && store.pendingStorageWrites == 0)
        #expect(try store.items(matching: .init()) == [item])
        key.unavailable = true
        let forgotten = JournalItem(id: "forgotten", time: Date(), level: .focus, kind: .focus, payload: .init(.init(description: "Do not restore")))
        try store.append(forgotten); try store.delete(.all)
        key.unavailable = false; store.retryPendingWrites()
        #expect(try store.items(matching: .init()).isEmpty)
        #expect(!key.requiresProtectedFiles)
        #expect(KeychainJournalKeyProvider().requiresProtectedFiles) // no key() call, no Keychain access
    }
    @Test func unavailableRulesLaunchPreservesUnknownDiskAndRecoversThenQueuesChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2_rules_recovery_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = RecoverableFixtureKey(), file = root.appendingPathComponent("rules.zrules")
        let original = try PersistentRulesStore(fileURL: file, keyProvider: key)
        let rule = try original.addOwn(.init(sentence: "Keep synthetic updates short"), at: Date())
        let bytes = try Data(contentsOf: file)
        key.unavailable = true
        let recovered = try PersistentRulesStore(fileURL: file, keyProvider: key)
        #expect(recovered.storageWaitingForUnlock && recovered.rules.isEmpty)
        #expect(throws: LearningStorageError.self) { try recovered.addOwn(.init(sentence: "Do not overwrite unknown state"), at: Date()) }
        #expect(try Data(contentsOf: file) == bytes)
        key.unavailable = false; recovered.retryPendingWrites()
        #expect(recovered.rules == [rule] && !recovered.storageWaitingForUnlock)
        key.unavailable = true
        var emitted = 0; recovered.onRuleOutcome = { _, _, _, _ in emitted += 1 }
        try recovered.setStatus(.proposed, id: rule.id, at: Date())
        #expect(recovered.pendingStorageWrites == 1 && recovered.storageWaitingForUnlock)
        #expect(emitted == 0)
        #expect(try Data(contentsOf: file) == bytes)
        key.unavailable = false; recovered.retryPendingWrites(); recovered.retryPendingWrites()
        #expect(emitted == 1 && !recovered.storageWaitingForUnlock)
        let reopened = try PersistentRulesStore(fileURL: file, keyProvider: key)
        #expect(reopened.rules.first?.status == .proposed)
    }
}
