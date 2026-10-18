import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@Suite @MainActor struct PA1ProactiveTests {
    private func settings() throws -> (MorningBriefSettings, UserDefaults, String) {
        let name = "pa1-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = MorningBriefSettings(defaults: defaults)
        settings.enabled = true
        return (settings, defaults, name)
    }
    @Test func defaultIsManagedOnlyAndTimeClampsPersist() throws {
        let name = "pa1-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let value = MorningBriefSettings(defaults: defaults)
        #expect(value.effectiveEnabled(managed: true)); #expect(!value.effectiveEnabled(managed: false))
        #expect(value.hour == 8 && value.minute == 0)
        value.enabled = true; value.hour = 25; value.minute = -1
        let restored = MorningBriefSettings(defaults: defaults)
        #expect(restored.effectiveEnabled(managed: false)); #expect(restored.hour == 23 && restored.minute == 0)
    }
    @Test(arguments: [0, 1, 2, 3, 4])
    func briefUsesOnlyEnabledLevelsAndNeverTypedWords(level: Int) async throws {
        let (settings, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let levels = Set(JournalLevel.allCases.filter { $0.rawValue == level })
        let f = try LearningRuntimeFixture(morningBriefSettings: settings, morningBriefLevels: { levels })
        defer { f.stop() }
        for itemLevel in JournalLevel.allCases {
            try f.journal.append(.init(id: "evidence-\(itemLevel.rawValue)", time: f.clock.now.addingTimeInterval(-86400), level: itemLevel,
                kind: itemLevel == .typed ? .typedText : (itemLevel == .screen ? .description : (itemLevel == .focus ? .focus : .activity)),
                payload: .init(.init(description: "level-\(itemLevel.rawValue)", text: "NEVER_RAW_WORDS", topic: "level-4"))))
        }
        f.runtime.noteProactiveActivity(at: f.clock.now)
        f.runtime.noteProactiveActivity(at: f.clock.now)
        let brief = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .brief })
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .brief }.count == 1)
        #expect(brief.delivery.content.contains("about \"Morning brief\""))
        #expect(!brief.delivery.content.contains("NEVER_RAW_WORDS"))
        for candidate in 1...4 { #expect(brief.delivery.content.contains("level-\(candidate)") == (candidate == level)) }
        #expect(brief.delivery.content.contains("yesterday's summary") == (level != 0))
        #expect(brief.delivery.content.contains("Unprompted messages left today: 6"))
        f.runtime.stop(); try f.runtime.start(); f.runtime.noteProactiveActivity(at: f.clock.now)
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .brief }.count == 1)
    }
    @Test func briefSummaryIsSixBoundedLinesAndDeletionSuppressesLateReceipt() throws {
        let (settings, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        let f = try LearningRuntimeFixture(morningBriefSettings: settings, morningBriefLevels: { [.focus] })
        defer { f.stop() }
        for index in 0..<9 {
            try f.journal.append(.init(id: "summary-\(index)", time: f.clock.now.addingTimeInterval(-86400 + Double(index)), level: .focus, kind: .focus,
                payload: .init(.init(description: "Synthetic work\nwith multiple\nlines " + String(repeating: "x", count: 300)))))
        }
        f.runtime.noteProactiveActivity(at: f.clock.now)
        let brief = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .brief })
        let lines = brief.delivery.content.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == 6); #expect(lines.allSatisfy { $0.count <= 242 })
        try f.journal.delete(.all)
        _ = try f.runtime.acknowledge(ids: [brief.delivery.id], sessionKey: "claude:/fixture#123.1")
        f.runtime.recordReflectionReceipt(id: brief.delivery.id)
        #expect(f.runtime.ledger?.record(id: brief.delivery.id)?.discardedAt != nil)
        #expect(try f.journal.items(matching: .init()).isEmpty)
    }
    @Test func fixedTimeHasNoEarlyBriefAndDisabledBriefNeverQueues() throws {
        let (settings, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.schedule = .fixedTime; settings.hour = 19
        let f = try LearningRuntimeFixture(morningBriefSettings: settings); defer { f.stop() }
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .brief }.isEmpty == true)
        f.clock.advance(3600); f.runtime.proactiveSettingsDidChange()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .brief }.count == 1)
        settings.enabled = false; f.runtime.proactiveSettingsDidChange()
        #expect(f.runtime.ledger?.records.first { $0.delivery.kind == .brief }?.discardedAt != nil)
        f.clock.advance(86400); f.runtime.noteProactiveActivity(at: f.clock.now)
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .brief }.count == 1)
    }
    @Test(arguments: [
        ("2026-03-08T07:00:00Z", 2, 30, "2026-03-08T08:00:00Z"),
        ("2026-03-08T08:05:00Z", 2, 30, "2026-03-09T07:30:00Z"),
        ("2026-11-01T05:00:00Z", 1, 30, "2026-11-01T06:30:00Z"),
        ("2026-11-01T06:45:00Z", 1, 30, "2026-11-02T07:30:00Z"),
        ("2026-11-01T07:15:00Z", 1, 30, "2026-11-02T07:30:00Z"),
        ("2026-10-30T14:00:00Z", 8, 0, "2026-10-31T13:00:00Z")
    ])
    func fixedBriefMatchesConfiguredWallTimeAcrossDST(now: String, hour: Int, minute: Int, expected: String) throws {
        let (settings, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.schedule = .fixedTime; settings.hour = hour; settings.minute = minute
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let f = try LearningRuntimeFixture(morningBriefSettings: settings, calendar: calendar); defer { f.stop() }
        f.clock.now = try #require(ISO8601DateFormatter().date(from: now))
        #expect(f.runtime.nextBriefBoundary == ISO8601DateFormatter().date(from: expected))
    }
    @Test func repeatedHourDoesNotDeliverTwoBriefsOnTheSameLocalDay() throws {
        let (settings, defaults, name) = try settings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.schedule = .fixedTime; settings.hour = 1; settings.minute = 30
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let f = try LearningRuntimeFixture(morningBriefSettings: settings, calendar: calendar); defer { f.stop() }
        f.clock.now = try #require(ISO8601DateFormatter().date(from: "2026-11-01T06:30:00Z"))
        f.runtime.considerMorningBrief()
        f.clock.advance(3600); f.runtime.considerMorningBrief()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.meta["brief_day"] == "2026-11-01" }.count == 1)
    }
    @Test func actingContextRearmsButPassiveNeverDeliversAndRestartDoesNotDuplicate() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Prepare the test recap", trigger: .init(state: "tests done"), kind: .acts)], at: f.clock.now).first)
        _ = try f.rules.propose([.init(sentence: "Quiet during tests", trigger: .init(state: "tests done"))], at: f.clock.now)
        f.box.context.states = ["tests done"]; f.runtime.learningContextDidChange(); f.runtime.learningContextDidChange()
        let first = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .ruleTrigger })
        #expect(first.delivery.meta["rule_id"] == rule.id)
        #expect(first.delivery.content.contains("shadow, waiting for my OK"))
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .ruleTrigger }.count == 1)
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .ruleTrigger }.count == 1)
        f.box.context.states = []; f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.record(id: first.delivery.id)?.discardedAt != nil)
        f.box.context.states = ["tests done"]; f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .ruleTrigger }.count == 2)
    }
    @Test func timedWindowDoesNotRefireAfterAppSwitchAndRearmsTomorrow() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        _ = try f.rules.propose([.init(sentence: "Prepare the afternoon recap", trigger: .init(time: .init(startMinute: 18 * 60, endMinute: 19 * 60), apps: ["com.example.fixture"]), kind: .acts)], at: f.clock.now)
        f.box.context.frontmostApp = "com.example.fixture"; f.runtime.learningContextDidChange()
        f.box.context.frontmostApp = nil; f.runtime.learningContextDidChange()
        f.box.context.frontmostApp = "com.example.fixture"; f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .ruleTrigger }.count == 1)
        f.clock.advance(86400); f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .ruleTrigger }.count == 2)
    }
    @Test func approvalCancelsQueuedShadowWithoutActingAgainInTheSameWindow() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Prepare the test recap", trigger: .init(state: "ready"), kind: .acts)], at: f.clock.now).first)
        f.box.context.states = ["ready"]; f.runtime.learningContextDidChange()
        let queued = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .ruleTrigger })
        try f.rules.recordAction(.init(id: "first-shadow", ruleID: rule.id, sessionKey: "fixture", text: "prepared a test recap",
                                      undo: nil, created: f.clock.now, kind: .shadow))
        try f.rules.setStatus(.active, id: rule.id, at: f.clock.now)
        f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.record(id: queued.delivery.id)?.discardedAt != nil)
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .ruleTrigger }.count == 1)
        f.box.context.states = []; f.runtime.learningContextDidChange()
        f.box.context.states = ["ready"]; f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .ruleTrigger }.count == 2)
        #expect(f.runtime.ledger?.records.last?.delivery.meta["rule_status"] == "active")
    }
    @Test func actedToolAcceptsOpenWindowAndRefusesAfterItCloses() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Prepare the test recap", trigger: .init(state: "ready"), kind: .acts)], at: f.clock.now).first)
        try f.rules.recordAction(.init(id: "first-shadow", ruleID: rule.id, sessionKey: "fixture", text: "prepared a test recap",
                                      undo: nil, created: f.clock.now, kind: .shadow))
        try f.rules.setStatus(.active, id: rule.id, at: f.clock.now)
        f.box.context.states = ["ready"]; f.runtime.learningContextDidChange()
        let args: JSONValue = ["ruleID": .string(rule.id), "did": "Prepared a synthetic recap", "undo": "Discard the recap"]
        #expect(!(await f.runtime.callTool("zeus_rule_acted", arguments: args, sessionKey: "claude:/fixture#123.1")).isError)
        f.box.context.states = []; f.runtime.learningContextDidChange()
        #expect((await f.runtime.callTool("zeus_rule_acted", arguments: args, sessionKey: "claude:/fixture#123.1")).isError)
        #expect(f.rules.ruleActions.filter { $0.kind == .acted }.count == 1)
    }
    @Test func seventhUnpromptedCardIsHeldBeforeArrivalButUrgencyAndRepliesAreExempt() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        for index in 0..<6 {
            let result = await f.runtime.callTool("zeus_say", arguments: ["text": .string("Update \(index)")], sessionKey: "claude:/fixture#123.1")
            #expect(!result.isError); #expect(f.cards.values.last?.muteDecision == nil)
        }
        f.cards.onAdd = { card in #expect(card.muteDecision?.source == .dailyBudget) }
        _ = await f.runtime.callTool("zeus_say", arguments: ["text": "Seventh update"], sessionKey: "claude:/fixture#123.1")
        f.cards.onAdd = nil
        let held = try #require(f.cards.values.last)
        try f.runtime.showBudgetHeldCard(id: held.id)
        #expect(f.cards.card(id: held.id)?.muteDecision?.releasedAt != nil)
        #expect(f.cards.card(id: held.id)?.muteDecision?.source == .dailyBudget)
        _ = await f.runtime.callTool("zeus_say", arguments: ["text": "Urgent", "priority": "high"], sessionKey: "claude:/fixture#123.1")
        #expect(f.cards.values.last?.muteDecision == nil)
        f.runtime.stop(); try f.runtime.start()
        #expect(f.runtime.remainingUnpromptedBudget == 0)
        let reply = try f.runtime.applyProactiveBudget(.init(kind: .message, body: "Requested response", origin: .reply))
        #expect(reply.muteDecision == nil)
        f.clock.advance(86400)
        #expect(f.runtime.remainingUnpromptedBudget == 6)
    }
}
