import AppKit
import Carbon
import Foundation
import Testing
@testable import Zeus

private struct TypingFixtureProse: ProseRedacting {
    var fails = false
    func spans(in text: String) async -> [ProsePrivateSpan]? {
        if fails { return nil }
        return [ProsePrivateSpan(text: "priya", kind: .name), .init(text: "knee", kind: .health),
                .init(text: "4200 euros", kind: .finance), .init(text: "purple kite", kind: .secret)]
    }
}
private actor ExcludedTypingProcessor: TypingRunRedacting {
    var calls = 0
    func redact(words: Redacted<String>, app: String) async -> RedactedTypingRun? {
        calls += 1
        return nil
    }
}
private struct TypingFixtureModel: TypingTopicGenerating {
    func generate(app: String, words: String) async -> TypingTopic? {
        .init(app: app, intent: .coding, subject: "Reviewing a synthetic change", recipients: ["colleague"])
    }
}
private actor TypingSuspendedProcessor: TypingRunRedacting {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func redact(words: Redacted<String>, app: String) async -> RedactedTypingRun? {
        entered = true; await withCheckedContinuation { continuation = $0 }
        return .init(app: .init("Fixture"), words: words, wordCount: 4)
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private final class TypingFixtureSource: TypingEventSource {
    var hasPermission = true
    var permissionRequestResult: Bool?
    var requests = 0, starts = 0, stops = 0, resets = 0
    var disabled: (() -> Void)?
    var shouldRead: (() -> Bool)?
    var onKey: ((TypingKey) -> Void)?
    func requestPermission() -> Bool { requests += 1; return permissionRequestResult ?? hasPermission }
    func start(shouldRead: @escaping () -> Bool, onKey: @escaping (TypingKey) -> Void, onDisabled: @escaping () -> Void) -> Bool {
        starts += 1; self.shouldRead = shouldRead; self.onKey = onKey; disabled = onDisabled; return hasPermission
    }
    func resetTranslation() { resets += 1 }
    func stop() { stops += 1; shouldRead = nil; onKey = nil; disabled = nil }
    func send(_ key: TypingKey) { if shouldRead?() == true { onKey?(key) } }
}
@MainActor private final class TypingFixture {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var policy = TypingPolicy(enabled: true, consented: true, apps: ["com.example.Editor"])
    var context = TypingContext(bundleID: "com.example.Editor", appName: "Fixture", windowID: 1, processID: 42)
    var secure = false, model = true
    let source = TypingFixtureSource()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2c_" + UUID().uuidString)
    let journal: EncryptedJournalStore
    var observer: TypingObserver!
    init(processor: (any TypingRunRedacting)? = nil) {
        journal = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        observer = TypingObserver(journal: journal, redactor: LocalRedactor(prose: TypingFixtureProse()),
            policy: { [unowned self] in policy }, context: { [unowned self] in context }, source: source,
            processor: processor, summarizer: TopicSummarizer(model: TypingFixtureModel()),
            modelAvailable: { [unowned self] in model }, secureInput: { [unowned self] in secure }, clock: { [unowned self] in now })
    }
    func close() { observer.stop(); try? FileManager.default.removeItem(at: root) }
    func finish() { now += 2; observer.tick() }
    func rows() throws -> [JournalItem] { try journal.items(matching: .init()) }
    func wait(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if try rows().count == count { return }; try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Typing fixture expected \(count) rows; pause=\(String(describing: observer.pause)), error=\(String(describing: observer.lastError))")
    }
}
@Suite @MainActor struct TypingLearningTests {
    @Test func threeRecordedLayoutsAndDeadKeys() throws {
        let cases: [(String, String, [(UInt16, CGEventFlags)])] = [
            ("com.apple.keylayout.US", "hello É é", [(4, []),(14, []),(37, []),(37, []),(31, []),(49, []),(14, .maskAlternate),(14, .maskShift),(49, []),(14, .maskAlternate),(14, [])]),
            ("com.apple.keylayout.German", "zy ä", [(16, []),(6, []),(49, []),(39, [])]),
            ("com.apple.keylayout.French", "aq ê", [(12, []),(0, []),(49, []),(33, []),(14, [])])]
        for (id, expected, keys) in cases {
            var translator = try #require(TypingKeyTranslator(sourceID: id), "Installed recorded layout is missing: \(id)")
            #expect(keys.map { translator.text(code: $0.0, flags: $0.1) }.joined() == expected)
        }
        var cancelled = try #require(TypingKeyTranslator(sourceID: "com.apple.keylayout.US"))
        #expect(cancelled.text(code: 14, flags: .maskAlternate).isEmpty)
        let didCancel = cancelled.cancelPendingDeadKey(); #expect(didCancel)
        #expect(cancelled.text(code: 14, flags: []) == "e")
    }
    @Test func coalescingGapFocusBackspaceAndPasteMarker() async throws {
        let f = TypingFixture(); defer { f.close() }; f.observer.start()
        f.source.send(.text("review a synthetic changx")); f.source.send(.backspace); f.source.send(.text("e "))
        f.source.send(.paste(changeCount: 3)); f.source.send(.text(" later"))
        f.now += 1.99; f.observer.tick(); #expect(try f.rows().isEmpty)
        f.now += 0.01; f.observer.tick(); try await f.wait(1)
        let row = try #require(f.rows().first)
        #expect(row.payload.value.text == "review a synthetic change ‹pasted› later")
        #expect(row.payload.value.details["pasteCount"] == "1"); #expect(row.payload.value.topic != nil)
        f.source.send(.text("second synthetic editing run")); f.context.windowID = 2; f.observer.contextDidChange()
        try await f.wait(2)
        f.source.send(.text("third synthetic editing run")); f.finish(); try await f.wait(3)
    }
    @Test func emptyDeadKeyOutputRefreshesGapAndIdleDoesNotClearPendingTranslation() async throws {
        let f = TypingFixture(); defer { f.close() }; f.observer.start()
        var translator = try #require(TypingKeyTranslator(sourceID: "com.apple.keylayout.US"))
        f.source.send(.text("review synthetic pars")); f.now += 1.5
        let accent = translator.text(code: 14, flags: .maskAlternate); #expect(accent.isEmpty)
        f.source.send(.text(accent)); f.now += 1; f.observer.tick()
        for _ in 0..<20 { await Task.yield() }; #expect(try f.rows().isEmpty)
        f.source.send(.text(translator.text(code: 14, flags: [])))
        let resets = f.source.resets; f.finish(); try await f.wait(1)
        #expect(try f.rows().first?.payload.value.text == "review synthetic parsé")
        #expect(f.source.resets == resets)
        f.context.windowID += 1; f.observer.contextDidChange(); #expect(f.source.resets > resets)
    }
    @Test(arguments: ["disabled", "consent", "model", "permission", "secure", "contextSecure", "private", "lock", "empty", "privateList"])
    func hardStopsBeforeKeys(reason: String) throws {
        let f = TypingFixture(); defer { f.close() }
        switch reason {
        case "disabled": f.policy.enabled = false
        case "consent": f.policy.consented = false
        case "model": f.model = false
        case "permission": f.source.hasPermission = false
        case "secure": f.secure = true
        case "contextSecure": f.context.secureInput = true
        case "private": f.context.isPrivate = true
        case "lock": f.context.isLocked = true
        case "empty": f.policy.apps = []
        default: f.policy.privateApps = [f.context.bundleID]
        }
        f.observer.start(); f.source.send(.text("must never keep this")); f.finish()
        #expect(try f.rows().isEmpty); #expect(f.source.requests == 0)
    }
    @Test func excludedWarpNeverReachesSystemFieldRedactionPath() async throws {
        let processor = ExcludedTypingProcessor(), f = TypingFixture(processor: processor)
        defer { f.close() }
        f.context.appName = "Warp"; f.policy.privateApps = [f.context.bundleID]
        f.observer.start(); f.source.send(.text("Synthetic work in Warp")); f.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(await processor.calls == 0)
        #expect(try f.rows().isEmpty)
    }

    @Test func secureInputDiscardsUsernameRunAndNeverCreatesNotice() async throws {
        let f = TypingFixture(); defer { f.close() }; f.observer.start()
        f.source.send(.text("synthetic username before password")); f.secure = true; f.observer.tick()
        #expect(f.observer.privateInput); f.source.send(.text("never capture password")); f.finish()
        #expect(try f.rows().isEmpty)
        f.secure = false; f.observer.tick(); #expect(!f.observer.privateInput)
        f.source.send(.text("normal synthetic typing resumed")); f.finish(); try await f.wait(1)
    }
    @Test(arguments: ["delete", "disable", "secure", "private", "permission", "scope", "stop"])
    func revalidatesAfterSemanticSuspension(change: String) async throws {
        let processor = TypingSuspendedProcessor(), f = TypingFixture(processor: processor); defer { f.close() }
        f.observer.start(); f.source.send(.text("safe fixture words here")); f.finish()
        for _ in 0..<1000 { if await processor.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await processor.entered)
        switch change {
        case "delete": f.observer.invalidatePendingCapture(); try f.journal.delete(.all)
        case "disable": f.policy.enabled = false
        case "secure": f.secure = true
        case "private": f.context.isPrivate = true
        case "permission": f.source.hasPermission = false
        case "stop": f.observer.stop()
        default: f.policy.apps = []
        }
        await processor.release()
        for _ in 0..<50 { await Task.yield() }
        #expect(try f.rows().isEmpty)
    }
    @Test func topicsOnlyShortRunsIMEAndBoundedRuns() async throws {
        let f = TypingFixture(); defer { f.close() }; f.policy.words = .none; f.observer.start()
        f.source.send(.text("a synthetic change here")); f.finish(); try await f.wait(1)
        #expect(try f.rows().first?.payload.value.text == nil)
        f.policy.words = .day; f.source.send(.text("fix typo")); f.finish(); try await f.wait(2)
        #expect(try f.rows().last?.payload.value.text == nil)
        f.source.send(.ime); f.source.send(.ime); f.finish(); try await f.wait(3)
        let ime = try #require(f.rows().last); #expect(ime.payload.value.topic == nil); #expect(ime.payload.value.text == nil)
        #expect(ime.payload.value.description == "Typed in Fixture")
        f.source.send(.text(String(repeating: "edit ", count: 401))); f.finish(); try await f.wait(5)
        #expect(try f.rows().compactMap { $0.payload.value.text }.allSatisfy { $0.count <= 2000 })
    }
    @Test func deferralResumesOnlyStageOneAndExpiresAfterTenMinutes() async throws {
        let f = TypingFixture(); defer { f.close() }; f.policy.deferProcessing = true; f.observer.start()
        f.source.send(.text("review synthetic project changes")); f.finish(); #expect(try f.rows().isEmpty)
        f.policy.deferProcessing = false; f.observer.tick(); try await f.wait(1)
        f.policy.deferProcessing = true; f.source.send(.text("old synthetic project changes")); f.finish()
        f.now += 600; f.policy.deferProcessing = false; f.observer.tick()
        for _ in 0..<30 { await Task.yield() }; #expect(try f.rows().count == 1)
    }
    @Test func explicitPermissionOnlyAndRevocationDropsCurrentRun() throws {
        let f = TypingFixture(); defer { f.close() }; f.source.hasPermission = false; f.policy.consented = false
        f.observer.start(); _ = f.observer.requestPermission(); #expect(f.source.requests == 0)
        f.policy.consented = true; #expect(f.observer.requestPermission() == .denied); #expect(f.source.requests == 1)
        f.source.hasPermission = true; f.observer.contextDidChange(); #expect(f.observer.isRecording)
        f.source.send(.text("must discard partial input")); f.source.hasPermission = false; f.source.disabled?()
        #expect(f.observer.permission == .revoked); #expect(!f.observer.isRecording)
        #expect(try f.rows().map(\.kind) == [.outcome]); f.observer.tick(); #expect(try f.rows().count == 1)
    }
    @Test func reopenRequiresPositiveRequestEvidenceAndDisabledInputShowsNoPrivateCue() throws {
        let f = TypingFixture(); defer { f.close() }; f.source.hasPermission = false; f.observer.start()
        #expect(!f.observer.permissionGrantedRequiresReopen)
        f.source.permissionRequestResult = true; _ = f.observer.requestPermission()
        #expect(f.observer.permissionGrantedRequiresReopen)
        f.source.hasPermission = true; f.observer.tick(); #expect(!f.observer.permissionGrantedRequiresReopen)
        f.source.hasPermission = false; f.observer.tick()
        #expect(f.observer.permission == .revoked); #expect(!f.observer.permissionGrantedRequiresReopen)
        f.source.hasPermission = true; f.observer.tick()
        f.secure = true; f.observer.tick(); #expect(f.observer.privateInput)
        f.policy.enabled = false; f.observer.tick(); #expect(!f.observer.privateInput)
        f.observer.stop(); #expect(!f.observer.privateInput)
    }
    @Test func semanticDeclineKeepsNothingAndExposesAnHonestNonPrivateError() async throws {
        let f = TypingFixture(processor: RunRedactor(redactor: LocalRedactor(prose: TypingFixtureProse(fails: true))))
        defer { f.close() }; f.observer.start(); f.source.send(.text("review a synthetic change")); f.finish()
        let until = ContinuousClock.now.advanced(by: .seconds(15))
        while f.observer.lastError == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.observer.lastError != nil); #expect(try f.rows().isEmpty)
        #expect(f.observer.lastError?.contains("synthetic") == false)
    }
    @Test func semanticPassIsRequiredAndEntireSecretsAreDropped() async throws {
        let stageOne = LocalRedactor.firstPass("review with priya about knee and 4200 euros")
        let safe = try #require(await RunRedactor(redactor: LocalRedactor(prose: TypingFixtureProse())).redact(words: stageOne, app: "Fixture"))
        for value in ["priya", "knee", "4200 euros"] { #expect(!safe.words.value.contains(value)) }
        #expect(safe.words.report.semanticEngine == .onDeviceModel)
        #expect(await RunRedactor(redactor: LocalRedactor(prose: TypingFixtureProse(fails: true))).redact(words: stageOne, app: "Fixture") == nil)
        for secret in ["sk-ant-abcdefghijklmnopqrstuvwxyz12345", "password is purple kite", "447-11-1234"] {
            #expect(await RunRedactor(redactor: LocalRedactor(prose: TypingFixtureProse())).redact(words: LocalRedactor.firstPass(secret), app: "Fixture") == nil)
        }
    }
    @Test func topicSchemaPostcheckAndOldPayloadCompatibility() throws {
        let good = TypingTopic(app: "Fixture", intent: .drafting, subject: "Drafting a synthetic project update", recipients: ["manager"])
        #expect(try JSONDecoder().decode(TypingTopic.self, from: JSONEncoder().encode(good)) == good)
        let unsafe = TopicSummarizer.checked(.init(app: "Other", intent: .replying, subject: "Call 555-123-4567", recipients: ["doctor"]), app: "Fixture")
        #expect(unsafe.subject == "Replying in Fixture"); #expect(unsafe.recipients == ["doctor"])
        let unknown = TopicSummarizer.checked(.init(app: "Other", intent: .replying, subject: "Project update", recipients: ["priya"]), app: "Fixture")
        #expect(unknown.subject == "Project update"); #expect(unknown.recipients.isEmpty)
        let old = try JSONDecoder().decode(JournalPayload.self, from: Data(#"{"description":"Old item","details":{}}"#.utf8))
        #expect(old.topic == nil && old.text == nil)
    }
    @Test func splitRetentionIsPreciseDurableSearchableAndLeavesLedgerAlone() throws {
        let f = TypingFixture(); defer { f.close() }
        func add(_ id: String, age: Double, kind: JournalKind = .typedText) throws {
            try f.journal.append(.init(id: id, time: f.now.addingTimeInterval(-age), level: .typed, app: f.context.bundleID, kind: kind,
                payload: .init(.init(description: "Safe topic", text: "local synthetic words", topic: "Safe topic", details: ["run_id": id]))))
        }
        try add("young", age: 86399); try add("oldWords", age: 86400); try add("oldTopic", age: 31*86400); try add("ledger", age: 40*86400, kind: .sentToAssistant)
        try f.journal.pruneTyping(words: .day, now: f.now)
        #expect(try f.rows().map(\.id) == ["ledger", "oldWords", "young"])
        #expect(try f.rows().first { $0.id == "oldWords" }?.payload.value.text == nil)
        #expect(try f.rows().first { $0.id == "young" }?.payload.value.text != nil)
        try f.journal.pruneTyping(words: .week, now: f.now)
        try f.journal.prune(retention: .init(), now: f.now.addingTimeInterval(86400))
        #expect(try f.rows().first { $0.id == "young" }?.payload.value.text == nil) // Extending never resets the original deadline.
        try f.journal.pruneTyping(words: .none, now: f.now)
        let reopened = EncryptedJournalStore(root: f.root, keyProvider: FixtureJournalKey())
        let rows = try reopened.items(matching: .init())
        #expect(rows.first { $0.id == "young" }?.payload.value.text == nil)
        #expect(rows.first { $0.id == "ledger" }?.payload.value.text != nil)
        #expect(rows.filter { $0.kind == .typedText }.allSatisfy { $0.payload.value.topic == "Safe topic" })
        try f.journal.delete(.item("young")); #expect(try f.rows().allSatisfy { $0.id != "young" })
    }
    @Test func summariesNeverSubstituteRawWordsForTopic() {
        let rows = [JournalItem(level: .typed, kind: .typedText, payload: .init(.init(description: "NEVER_DESCRIPTION", text: "NEVER_WORDS", topic: "Editing a synthetic file"))),
                    .init(level: .typed, kind: .typedText, payload: .init(.init(description: "NEVER_IME", text: "NEVER_OTHER_WORDS")))]
        #expect(LearnFromMe.typingSummary(rows) == "Editing a synthetic file")
    }
    @Test func expiredWordsAreRemovedOnReadWithCaptureOffAndTimerDoesNotRetainStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2c_expiry_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var journal: EncryptedJournalStore? = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey(), clock: { now })
        let retainedStore = { [weak journal] in journal }
        try journal?.append(.init(id: "timed", time: now, level: .typed, kind: .typedText,
            payload: .init(.init(description: "A safe topic", text: "safe local fixture words", topic: "A safe topic"))))
        now += 86400
        let row = try #require(journal?.items(matching: .init()).first)
        #expect(row.payload.value.text == nil && row.payload.value.topic == "A safe topic")
        #expect(row.payload.value.details["words_not_kept"] == "expired24Hours")
        journal = nil; #expect(retainedStore() == nil)
        let reopened = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey(), clock: { now })
        #expect(try reopened.items(matching: .init()).first?.payload.value.text == nil)
    }
    @Test func topicRetentionChoicesPreserveOtherLevelsAndResumeAfterInitiallyPrivateInput() throws {
        let f = TypingFixture(); defer { f.close() }
        try f.journal.append(.init(id: "older-topic", time: f.now.addingTimeInterval(-45*86400), level: .typed, kind: .typedText,
            payload: .init(.init(description: "Safe topic", topic: "Safe topic"))))
        try f.journal.append(.init(id: "focus", time: f.now.addingTimeInterval(-45*86400), level: .focus, kind: .focus,
            payload: .init(.init(description: "Safe focus"))))
        try f.journal.pruneTyping(words: .none, topicsDays: 90, now: f.now); #expect(try f.rows().count == 2)
        try f.journal.pruneTyping(words: .none, topicsDays: 7, now: f.now); #expect(try f.rows().map(\.id) == ["focus"])
        f.secure = true; f.observer.start(); #expect(f.source.starts == 0)
        f.secure = false; f.observer.tick(); #expect(f.source.starts == 1 && f.observer.isRecording)
    }
    @Test func atomicGroupDeletionUndoRejectsConflictsAndCannotRestoreDisallowedWords() throws {
        let f = TypingFixture(); defer { f.close() }
        let rows = (0..<2).map { index in JournalItem(id: "group-\(index)", time: f.now, level: .typed, kind: .typedText,
            payload: .init(.init(description: "Safe topic", text: "safe synthetic words", topic: "Safe topic"))) }
        for row in rows { try f.journal.append(row) }
        let ids = Set(rows.map(\.id)), revision = f.journal.revision
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.path)
        #expect(throws: (any Error).self) { try f.journal.deleteTyping(ids: ids) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
        #expect(try f.rows() == rows); #expect(f.journal.revision == revision)
        let receipt = try f.journal.deleteTyping(ids: ids); #expect(try f.rows().isEmpty)
        try f.journal.append(rows[0]); #expect(throws: TypingJournalError.self) { try f.journal.restoreTyping(receipt) }
        try f.journal.delete(.item(rows[0].id)); try f.journal.restoreTyping(receipt)
        #expect(try f.rows() == rows)
        let preferenceReceipt = try f.journal.deleteTyping(ids: ids)
        try f.journal.pruneTyping(words: .none, topicsDays: 30, now: f.now)
        #expect(throws: TypingJournalError.self) { try f.journal.restoreTyping(preferenceReceipt) }
        // Single-run UI Undo through append obeys the new preference as well.
        try f.journal.append(rows[0]); #expect(try f.rows().first?.payload.value.text == nil)
        let forgotten = try f.journal.deleteTyping(ids: [rows[0].id]); try f.journal.delete(.all)
        #expect(throws: TypingJournalError.self) { try f.journal.restoreTyping(forgotten) }
    }
    @Test func groupUndoStripsExpiredWordsAndCrossDayOrMissingSelectionChangesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2c_group_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let journal = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey(), clock: { now })
        let row = JournalItem(id: "old", time: now.addingTimeInterval(-86399), level: .typed, kind: .typedText,
            payload: .init(.init(description: "Safe topic", text: "synthetic words", topic: "Safe topic")))
        let fresh = JournalItem(id: "new", time: now, level: .typed, kind: .typedText,
            payload: .init(.init(description: "New topic", text: "other synthetic words", topic: "New topic")))
        try journal.append(row); try journal.append(fresh)
        let before = try journal.items(matching: .init())
        #expect(throws: TypingJournalError.self) { try journal.deleteTyping(ids: ["old", "new"]) }
        #expect(throws: TypingJournalError.self) { try journal.deleteTyping(ids: ["old", "missing"]) }
        #expect(try journal.items(matching: .init()) == before)
        let receipt = try journal.deleteTyping(ids: ["old"]); now += 2; try journal.restoreTyping(receipt)
        let restored = try #require(journal.items(matching: .init()).first { $0.id == "old" })
        #expect(restored.payload.value.text == nil && restored.payload.value.topic == "Safe topic")
        let expired = try journal.deleteTyping(ids: ["old"]); now += 31 * 86400
        #expect(throws: TypingJournalError.self) { try journal.restoreTyping(expired) }
    }
    @Test func failedShorteningCannotExposeWordsOrResurrectThemOnUndo() throws {
        let f = TypingFixture(); defer { f.close() }
        let row = JournalItem(id: "words", time: f.now, level: .typed, kind: .typedText,
            payload: .init(.init(description: "A safe topic", text: "safe synthetic words", topic: "A safe topic")))
        try f.journal.append(row)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.path)
        #expect(throws: (any Error).self) { try f.journal.pruneTyping(words: .none, topicsDays: 30, now: f.now) }
        #expect(throws: (any Error).self) { try f.journal.items(matching: .init()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
        #expect(try f.rows().first?.payload.value.text == nil)
        try f.journal.delete(.item(row.id)); try f.journal.append(row)
        #expect(try f.rows().first?.payload.value.text == nil)
    }
}
