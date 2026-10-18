import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class DigestPolicyFixture {
    let root = URL(fileURLWithPath: "/tmp/fx20_" + UUID().uuidString.prefix(8))
    let suite = "zeus-digest-policy-" + UUID().uuidString
    let defaults: UserDefaults
    let clock = TestRuntimeClock()
    let journal: EncryptedJournalStore
    let learn: LearnFromMe
    let writer: LearningFolderWriter
    let runtime: ZeusRuntime
    let connector = FakeConnector()
    var policy = LearningOutboundPolicy(scopes: JournalLevel.allCases.map { .init(level: $0, chosenApps: nil) }, privateApps: [])
    let calendar: Calendar
    let day: Date

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        self.calendar = calendar
        clock.now = try #require(ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z"))
        day = clock.now.addingTimeInterval(-86400)
        let clock = clock
        journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: FixtureJournalKey(), calendar: calendar, clock: { clock.now })
        let settings = LearnSettings(defaults: defaults); settings.enabled = true
        learn = LearnFromMe(settings: settings, root: root.appendingPathComponent("Activity"), calendar: calendar, clock: { clock.now }, journal: journal, redactor: FixtureLearningRedactor())
        let folder = root.appendingPathComponent("assistant")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writer = LearningFolderWriter(journal: journal, rules: nil, stateURL: root.appendingPathComponent("manifest.json"), enabledLevels: { [.activity, .screen, .typed] }, calendar: calendar)
        writer.setFolder(folder)
        runtime = ZeusRuntime(cards: FakeCards(clock: clock), status: FakeStatus(), characters: FakeCharacters(), routing: FakeRouting(), clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"), connectors: [connector],
            targetIsDead: { _ in false }, learnings: learn.learnings, journal: journal, redactor: FixtureLearningRedactor(), learningFolder: writer)
        learn.outboundPolicy = { [weak self] in self?.policy }
        runtime.outboundLearningPolicy = { [weak self] in self?.policy }
        for (i, offset) in [0.0, 3600.0].enumerated() {
            let event = ActivityEvent(t: day.addingTimeInterval(offset), kind: .activate, app: "com.example.Allowed", name: "Allowed")
            try journal.append(.init(id: "activity-\(i)", time: event.t, level: .activity, app: event.app, kind: .activity, payload: .init(ActivityStore.payload(event))))
        }
        for (i, app) in ["com.example.Restricted", "com.example.Allowed"].enumerated() {
            try journal.append(.init(id: "screen-\(i)", time: day, level: .screen, app: app, kind: .description,
                payload: .init(.init(description: "SCREEN_\(i)"))))
            try journal.append(.init(id: "typing-\(i)", time: day, level: .typed, app: app, kind: .typedText,
                payload: .init(.init(description: "Typing", topic: "TOPIC_\(i)"))))
        }
        try runtime.start()
    }
    func restrict(_ kind: String) {
        switch kind {
        case "off": policy.scopes.removeAll { $0.level == .screen || $0.level == .typed }
        case "private": policy.privateApps = [.init(name: "Restricted", bundleIDs: ["com.example.Restricted"])]
        case "chosen":
            for i in policy.scopes.indices where policy.scopes[i].level != .activity {
                policy.scopes[i].chosenApps = [.init(name: "Allowed", bundleIDs: ["com.example.Allowed"])]
            }
        default: break
        }
    }
    func summaryFile() throws -> String {
        let directory = try #require(writer.folderURL).appendingPathComponent("Zeus/days/2026-10-18/summary.md")
        return try String(contentsOf: directory, encoding: .utf8)
    }
    func stop() { connector.release(); runtime.stop(); learn.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

@Suite @MainActor struct DigestPolicyTests {
    @Test(arguments: ["off", "private", "chosen", "allowed"])
    func filtersBeforeSamplingAndExport(_ restriction: String) async throws {
        let f = try DigestPolicyFixture(); defer { f.stop() }
        f.restrict(restriction)
        f.learn.sendDigestIfDue(now: f.clock.now)
        let digest = try #require(f.learn.learnings?.unreadLearnings().first)
        await f.writer.flush()
        let file = try f.summaryFile()
        #expect(file == digest.text + "\n\n")
        for text in [digest.text, file] {
            #expect(text.contains("SCREEN_0") == (restriction == "allowed"))
            #expect(text.contains("TOPIC_0") == (restriction == "allowed"))
            #expect(text.contains("SCREEN_1") == (restriction != "off"))
            #expect(text.contains("TOPIC_1") == (restriction != "off"))
        }
    }
    @Test func queuedRestrictionReplacesIdentityExportAndRejectsLateAck() async throws {
        let f = try DigestPolicyFixture(); defer { f.stop() }
        f.learn.sendDigestIfDue(now: f.clock.now)
        let old = try #require(f.learn.learnings?.unreadLearnings().first)
        try await eventually { f.runtime.ledger?.record(id: old.id) != nil }
        f.restrict("private")
        // No app Observation callback: even a tool/ack that wins the scheduling race must reconcile policy.
        _ = try f.runtime.acknowledge(ids: [old.id], sessionKey: "claude:/fixture#1.1")
        let new = try #require(f.learn.learnings?.unreadLearnings().first)
        #expect(new.id != old.id); #expect(!new.text.contains("SCREEN_0"))
        #expect(f.runtime.ledger?.record(id: old.id)?.discardedAt != nil)
        #expect(f.runtime.ledger?.record(id: old.id)?.delivery.ackedAt == nil)
        await f.writer.flush()
        #expect(try f.summaryFile() == new.text + "\n\n")
        #expect(try !f.journal.items(matching: .init()).contains { $0.kind == .sentToAssistant })
        // Durable provenance and the rebuilt text survive reopening the store.
        let reopened = LearningsStore(files: ActivityStore(root: f.root.appendingPathComponent("Activity"), journal: f.journal), isEnabled: { true })
        #expect(reopened.unreadLearnings().first?.id == new.id)
        #expect(reopened.digestMetadata(id: new.id)["privacy_policy"] == f.policy.fingerprint)
    }
    @Test func privateActivationStillClosesThePrecedingAllowedInterval() async throws {
        let f = try DigestPolicyFixture(); defer { f.stop() }
        for event in [ActivityEvent(t: f.day.addingTimeInterval(600), kind: .activate, app: "com.example.Restricted", name: "Restricted"),
                      ActivityEvent(t: f.day.addingTimeInterval(1800), kind: .idle)] {
            try f.journal.append(.init(time: event.t, level: .activity, app: event.app, kind: .activity, payload: .init(ActivityStore.payload(event))))
        }
        f.restrict("private"); f.learn.sendDigestIfDue(now: f.clock.now)
        let text = try #require(f.learn.learnings?.unreadLearnings().first?.text)
        #expect(text.contains("Top apps: Allowed 10 min."))
        #expect(text.contains("Private time: 20 min"))
        #expect(!text.contains("Restricted"))
        await f.writer.flush(); #expect(try f.summaryFile() == text + "\n\n")
    }
    @Test func policyChecksNameOnlyPrivateEntriesAgainstSystemAppName() {
        let policy = LearningOutboundPolicy(scopes: [.init(level: .typed, chosenApps: nil)], privateApps: [.init(name: "Private Editor", bundleIDs: [])])
        let item = JournalItem(time: Date(), level: .typed, app: "com.example.Editor", kind: .typedText,
            payload: .init(.init(description: "Typing", topic: "Safe topic", details: ["appName": "Private Editor"])))
        #expect(!policy.allows(item))
    }
    @Test func consumedSummaryKeepsItsExactHistoricalText() async throws {
        let f = try DigestPolicyFixture(); defer { f.stop() }
        f.learn.sendDigestIfDue(now: f.clock.now)
        let old = try #require(f.learn.learnings?.unreadLearnings().first)
        let key = "claude:/fixture#1.1"
        f.runtime.registerSession(.init(id: UUID(), sessionKey: key, agent: .claude, cwd: "/fixture", clientName: "Fixture", supportsChannel: true, tmuxPane: nil, connectedAt: f.clock.now))
        try await eventually { f.runtime.ledger?.record(id: old.id)?.delivery.sessionKey == key }
        #expect(try f.runtime.acknowledge(ids: [old.id], sessionKey: key) == [old.id])
        let receipts = try f.journal.items(matching: .init()).filter { $0.kind == .sentToAssistant }
        #expect(receipts.count == 1)
        f.restrict("off"); f.runtime.learningContextDidChange()
        #expect(f.learn.learnings?.allLearnings.first == old)
        #expect(try f.journal.items(matching: .init()).filter { $0.kind == .sentToAssistant } == receipts)
        await f.writer.flush()
        #expect(try f.summaryFile() == old.text + "\n\n")
    }
}

@Suite @MainActor struct OutboundPolicyTests {
    @Test func briefAndReflectionFilterScopeAndInvalidateQueuedSnapshots() async throws {
        let suite = "zeus-outbound-policy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MorningBriefSettings(defaults: defaults); settings.enabled = false
        let f = try LearningRuntimeFixture(exportFolder: true, morningBriefSettings: settings, morningBriefLevels: { [.focus] })
        defer { f.stop() }
        f.connector.available = false
        var policy = LearningOutboundPolicy(scopes: [.init(level: .focus, chosenApps: nil)], privateApps: [])
        f.runtime.outboundLearningPolicy = { policy }
        for offset in [-86400.0, 0] {
            for (id, app) in [("kept", "com.example.Allowed"), ("private", "com.example.Restricted")] {
                try f.journal.append(.init(id: id + String(offset), time: f.clock.now.addingTimeInterval(offset), level: .focus, app: app, kind: .focus,
                    payload: .init(.init(description: id == "private" ? "CANARY_PRIVATE" : "ALLOWED_WORK"))))
            }
        }
        settings.enabled = true; settings.schedule = .fixedTime; settings.hour = 0
        f.box.enabled = true; f.box.context.idleSince = f.clock.now.addingTimeInterval(-601)
        f.runtime.learningContextDidChange()
        try await eventually { f.runtime.ledger?.records.contains { $0.delivery.kind == .reflection && $0.isPending } == true }
        let before = try #require(f.runtime.ledger).records.filter { $0.isPending && [.brief, .reflection].contains($0.delivery.kind) }
        #expect(before.count == 2)
        #expect(before.allSatisfy { $0.delivery.content.contains("CANARY_PRIVATE") })
        policy.privateApps = [.init(name: "Restricted", bundleIDs: ["com.example.Restricted"])]
        f.runtime.learningContextDidChange()
        try await eventually {
            (f.runtime.ledger?.records.filter { $0.isPending && [.brief, .reflection].contains($0.delivery.kind) }.count ?? 0) == 2
        }
        let after = try #require(f.runtime.ledger).records.filter { $0.isPending && [.brief, .reflection].contains($0.delivery.kind) }
        #expect(after.allSatisfy { !$0.delivery.content.contains("CANARY_PRIVATE") && $0.delivery.content.contains("ALLOWED_WORK") })
        #expect(Set(before.map { $0.delivery.id }).isDisjoint(with: after.map { $0.delivery.id }))
        #expect(after.allSatisfy { !$0.delivery.meta.values.joined().contains("com.example.Restricted") })
        for old in before {
            #expect(try f.runtime.acknowledge(ids: [old.delivery.id], sessionKey: old.delivery.sessionKey).isEmpty)
        }
        await f.folder?.flush()
        let reflected = try #require(after.first { $0.delivery.kind == .reflection })
        let path = try #require(f.folder?.folderURL).appendingPathComponent("Zeus/reflections/2026-10-14.md")
        #expect(try String(contentsOf: path, encoding: .utf8) == reflected.delivery.content + "\n\n")
        #expect(try !f.journal.items(matching: .init()).contains { $0.kind == .sentToAssistant })
        // Returning to an earlier snapshot must not revive its discarded identity or strand the day.
        for privateApps in [[], [LearningOutboundPolicy.App(name: "Restricted", bundleIDs: ["com.example.Restricted"])]] {
            policy.privateApps = privateApps; f.runtime.learningContextDidChange()
            try await eventually {
                (f.runtime.ledger?.records.filter { $0.isPending && [.brief, .reflection].contains($0.delivery.kind) }.count ?? 0) == 2
            }
            let current = try #require(f.runtime.ledger).records.filter { $0.isPending && [.brief, .reflection].contains($0.delivery.kind) }
            #expect(current.allSatisfy { $0.delivery.content.contains("CANARY_PRIVATE") == privateApps.isEmpty })
            #expect(Set(current.map { $0.delivery.id }).isDisjoint(with: before.map { $0.delivery.id }))
        }
    }
}
