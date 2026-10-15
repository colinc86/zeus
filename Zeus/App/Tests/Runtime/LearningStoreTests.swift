import CryptoKit
import Foundation
import Observation
import Testing
import Synchronization
@testable import Zeus

@MainActor final class FixtureJournalKey: JournalKeyProviding {
    var bytes = Data(repeating: 42, count: 32)
    func key() throws -> Data { bytes }
}
@Suite @MainActor struct LearningStoreTests {
    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lm2_" + UUID().uuidString) }
    func item(_ id: String = UUID().uuidString, time: Date = Date(), level: JournalLevel = .focus,
              kind: JournalKind = .focus, app: String = "com.example.Editor") -> JournalItem {
        .init(id: id, time: time, level: level, app: app, kind: kind,
              payload: .init(.init(description: "Café ‹email›", text: "redacted text")))
    }
    @Test func encryptionSearchDeletionExportAndRecovery() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let key = FixtureJournalKey(), store = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        let first = item("one"), second = item("two", app: "com.example.Other")
        try store.append(first); try store.append(first); try store.append(second)
        #expect(store.revision == 2)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(!String(decoding: try Data(contentsOf: files[0]), as: UTF8.self).contains("redacted text"))
        #expect((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reopened = EncryptedJournalStore(root: root, keyProvider: key)
        var query = JournalQuery(); query.text = "CAFE"
        #expect(try reopened.items(matching: query).count == 2)
        #expect(String(decoding: try reopened.export(matching: query), as: UTF8.self).contains("‹email›"))
        try reopened.delete(.item("one")); try reopened.append(first)
        #expect(try reopened.items(matching: .init()).count == 2)
        try reopened.delete(.app("com.example.Other")); #expect(try reopened.items(matching: .init()).map(\.id) == ["one"])
        try reopened.delete(.day(first.time)); #expect(try reopened.items(matching: .init()).isEmpty)
    }
    @Test func authenticationFailureNeverOverwritesOrPublishes() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let key = FixtureJournalKey(), store = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        try store.append(item())
        key.bytes = Data(repeating: 43, count: 32)
        let wrong = EncryptedJournalStore(root: root, keyProvider: key)
        #expect(throws: LearningStorageError.self) { try wrong.append(item()) }
        #expect(wrong.revision == 0); #expect(wrong.lastError != nil)
        #expect(try store.items(matching: .init()).count == 1)
        #expect(throws: LearningStorageError.self) { try store.append(item(kind: .frame)) }
    }
    @Test func retentionAndSentLedger() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        let now = Date(), old = now.addingTimeInterval(-45*86400)
        try store.append(item("l1", time: old, level: .activity))
        try store.append(item("l2", time: old))
        try store.append(item("l3", time: old, level: .screen, kind: .description))
        try store.append(item("l4", time: old, level: .typed, kind: .typedText))
        try store.append(item("sent", kind: .sentToAssistant))
        try store.prune(retention: .init(), now: now)
        #expect(try store.items(matching: .init()).count == 4)
        try store.delete(.item("sent")); #expect(try store.items(matching: .init()).count == 4)
        try store.delete(.all); #expect(try store.items(matching: .init()).isEmpty)
    }
    @Test func rulesConsentAtomicValidationOutcomesAndUndo() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let key = FixtureJournalKey(), url = root.appendingPathComponent("rules.zrules")
        let store = try PersistentRulesStore(fileURL: url, keyProvider: key), now = Date()
        let rules = try store.propose([.init(sentence: "Stay quiet during tests", trigger: .init(state: "tests failing")),
                                      .init(sentence: "Send a summary", kind: .acts)], at: now)
        #expect(rules.map(\.status) == [.active, .shadow]); #expect(store.autonomy == 0.5)
        #expect(throws: LearningStorageError.self) { try store.propose([.init(sentence: "valid"), .init(sentence: " ")], at: now) }
        #expect(store.rules.count == 2)
        try store.recordOutcome(.skipped, ruleIDs: [rules[0].id], eventID: "skip1", at: now)
        try store.recordOutcome(.skipped, ruleIDs: [rules[0].id], eventID: "skip1", at: now)
        #expect(abs(store.rules[0].confidence - 0.45) < 0.001)
        try store.recordOutcome(.undone, ruleIDs: [rules[0].id], eventID: "undo", at: now)
        try store.recordOutcome(.ignored, ruleIDs: [rules[0].id], eventID: "ignored", at: now)
        #expect(store.rules[0].status == .retired)
        let own = try store.addOwn(.init(sentence: "My own", evidence: ["entry"]), at: now)
        #expect(own.updatedBy == .user)
        try store.edit(id: own.id, sentence: "My edit", trigger: .init(), at: now)
        let edited = try #require(store.rules.last)
        #expect(edited.confidence == own.confidence && edited.evidence == own.evidence)
        try store.delete(id: own.id); try store.restoreDeleted(edited)
        #expect(store.rules.last == edited)
        store.autonomy = 0
        #expect(try store.propose([.init(sentence: "Ask first")], at: now)[0].status == .proposed)
        let reopened = try PersistentRulesStore(fileURL: url, keyProvider: key)
        #expect(reopened.rules == store.rules && reopened.autonomy == 0)
    }
    @Test func dialNeverSkipsFirstShadowAndUserCreationIsPassive() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        store.autonomy = 0
        let proposed = try store.propose([.init(sentence: "Send recap", kind: .acts)], at: Date())[0]
        #expect(proposed.status == .proposed)
        try store.setStatus(.active, id: proposed.id, at: Date())
        #expect(store.rules[0].status == .shadow)
        store.autonomy = 1
        let shadow = try store.propose([.init(sentence: "Post recap", kind: .acts)], at: Date())[0]
        #expect(shadow.status == .shadow)
        try store.recordOutcome(.accepted, ruleIDs: [shadow.id], at: Date())
        #expect(store.rules.last?.status == .shadow)
        _ = try store.markShadowShown(id: shadow.id)
        try store.recordOutcome(.accepted, ruleIDs: [shadow.id], at: Date())
        #expect(store.rules.last?.status == .active)
        let own = try store.addOwn(.init(sentence: "My rule", kind: .acts), at: Date())
        #expect(own.kind == .passive && own.updatedBy == .user && own.confidence == 0.75)
    }
    @Test func olderRuleSnapshotLoadsWithConsentAndNoticeHistoryDefaults() throws {
        struct OldState: Encodable { var rules: [LearnedRule]; var autonomy: Double }
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rules.zrules"), key = FixtureJournalKey()
        let first = try PersistentRulesStore(fileURL: url, keyProvider: key)
        let added = try first.propose([.init(sentence: "Use short updates")], at: Date())
        try LearningEncryption.write(OldState(rules: added, autonomy: 0), to: url, key: key)
        let reopened = try PersistentRulesStore(fileURL: url, keyProvider: key)
        #expect(reopened.rules == added && reopened.autonomy == 0)
        #expect(reopened.ruleNoticeGroups() == [added.map(\.id)])
    }
    @Test func dialPublishesChangesToObservers() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        let changes = Mutex(0)
        withObservationTracking { _ = store.autonomy } onChange: { changes.withLock { $0 += 1 } }
        store.autonomy = 0
        #expect(changes.withLock { $0 } == 1)
    }
    @Test func triggerANDPrivateAndOvernightWeekday() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 13, hour: 1)))
        let trigger = RuleTrigger(time: .init(startMinute: 22*60, endMinute: 2*60, weekdays: [2]), apps: ["com.example.Editor"], state: "tests failing")
        var context = LearningContext(frontmostApp: "com.example.Editor", states: ["tests failing"])
        #expect(trigger.matches(context, at: date, calendar: calendar))
        context.isPrivate = true; #expect(!trigger.matches(context, at: date, calendar: calendar))
        let clockOnly = RuleTrigger(time: .init(startMinute: 0, endMinute: 120))
        #expect(clockOnly.matches(context, at: date, calendar: calendar))
        context.isLocked = true; #expect(clockOnly.matches(context, at: date, calendar: calendar))
        #expect(!RuleTrigger().matches(.init(), at: date))
    }
}
