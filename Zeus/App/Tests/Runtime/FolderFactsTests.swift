import Foundation
import Testing
@testable import Zeus

@Suite @MainActor struct FolderFactsTests {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = .gmt; return value
    }
    @Test(arguments: ["12345", "08:41", "08:41–23:19", "14 h 32 min", "4 h 29 min", "17 min",
                      "Monday", "Friday", "October", "May"])
    func timeAndCalendarFactsAreNotNames(_ text: String) {
        #expect(LocalRedactor.isNonNameFact(text))
        #expect(LocalRedactor.firstPass(text).value == text)
    }
    @Test func genuinePrivateDetailsStillRedact() {
        let safe = LocalRedactor.firstPass("Meet John Smith at 08:41. Email john@example.test. password: synthetic-password")
        #expect(safe.value.contains("08:41"))
        #expect(!safe.value.contains("John Smith"))
        #expect(!safe.value.contains("john@example.test"))
        #expect(!safe.value.contains("synthetic-password"))
    }
    @Test func pseudoAppsHaveSeparateTimeAndNeverBecomeFirstOrTopApp() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ minute: Int, _ app: String?, _ name: String) -> ActivityEvent {
            .init(t: day.addingTimeInterval(Double(minute * 60)), kind: .activate, app: app, name: name)
        }
        let events = [event(0, "com.apple.universalcontrol", "Localized system name"),
                      event(269, "com.apple.loginwindow", "Localized login"),
                      event(270, nil, "ScreenSaverEngine"), event(271, "com.example.warp", "Warp"),
                      ActivityEvent(t: day.addingTimeInterval(354 * 60), kind: .lock)]
        let stats = LearningSummarizer.stats(events, excluded: [])
        #expect(stats.firstApp?.name == "Warp")
        #expect(stats.appSeconds == ["Warp": 83 * 60])
        #expect(stats.otherDeviceSeconds == 269 * 60)
        #expect(stats.activeSeconds == 354 * 60)
        let digest = try #require(LearningSummarizer.digest(day: day, events: events, previousStarts: [], excluded: [], calendar: Self.calendar))
        #expect(digest.contains("- Top apps: Warp 1 h 23 min."))
        #expect(digest.contains("- On another device: 4 h 29 min"))
        #expect(!digest.contains("Localized") && !digest.contains("ScreenSaverEngine"))
        let fallback = [event(0, nil, "Universal Control"), event(269, nil, "loginwindow"),
                        ActivityEvent(t: day.addingTimeInterval(270 * 60), kind: .lock)]
        #expect(LearningSummarizer.stats(fallback, excluded: []).otherDeviceSeconds == 269 * 60)
        #expect(LearningSummarizer.stats(fallback, excluded: []).firstApp == nil)
    }
    @Test func storedLearningsHealOwnedCopiesAndNeverRunThroughRedactorAgain() async throws {
        let learnings = FakeLearnings()
        let f = try LearningRuntimeFixture(learnings: learnings, redactor: DestructiveFactRedactor(), exportFolder: true)
        defer { f.stop() }
        let summary = "Zeus's summary of Friday, October 16 (app usage and timing only):\n- Active 08:41–23:19, about 14 h 32 min at the Mac.\n- First app: Warp at 08:46."
        let moment = "First activity today at 08:05."
        learnings.items = [.init(id: "summary", kind: .digest, createdAt: f.clock.now, text: summary),
                          .init(id: "moment", kind: .moment, createdAt: f.clock.now, text: moment)]
        let writer = try #require(f.folder)
        let root = try #require(writer.folderURL)
        // Seed old files through the real manifest, as an older version of Zeus would.
        for item in learnings.items {
            _ = await writer.recordLearning(.init(id: item.id, kind: item.kind, createdAt: item.createdAt, text: "‹name› ‹secret›"))
        }
        writer.stop()
        let restored = LearningFolderWriter(journal: f.journal, rules: f.rules, stateURL: f.root.appendingPathComponent("folder.json"),
            enabledLevels: { [.activity] }, redactor: DestructiveFactRedactor(), calendar: Self.calendar)
        restored.start(learnings: learnings); defer { restored.stop() }
        await restored.flush()
        #expect(restored.lastWriteError == nil)
        let directory = root.appendingPathComponent("Zeus/days/2026-10-14")
        #expect(try String(contentsOf: directory.appendingPathComponent("summary.md"), encoding: .utf8) == summary + "\n\n")
        #expect(try String(contentsOf: directory.appendingPathComponent("moments.md"), encoding: .utf8) == moment + "\n\n")
        let sent = await f.runtime.learningForSending(learnings.items[1])
        #expect(sent.text.hasPrefix(moment + "\n"))
        #expect(!sent.text.contains("‹secret›"))
    }
    @Test func reflectionAndMorningBriefPreserveGeneratedFactsAndAlreadyRedactedInputs() async throws {
        let name = "fx8-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MorningBriefSettings(defaults: defaults); settings.enabled = true
        let f = try LearningRuntimeFixture(redactor: DestructiveFactRedactor(), exportFolder: true,
            morningBriefSettings: settings, morningBriefLevels: { [.focus] })
        defer { f.stop() }
        let safeFact = "Review at 08:41 for 17 min with ‹name›."
        try f.journal.append(.init(id: "focus", time: f.clock.now.addingTimeInterval(-86400), level: .focus, kind: .focus,
            payload: .init(.init(description: safeFact))))
        f.runtime.noteProactiveActivity(at: f.clock.now)
        let brief = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .brief })
        #expect(brief.delivery.content.contains(safeFact))
        #expect(brief.delivery.content.contains("Wednesday 14 October"))
        let (day, rows) = ReflectionPatternTests.fixture()
        let digest = ReflectionPatternDigest(time: .init(calendar: ReflectionPatternTests.calendar), day: day,
            levels: Set(JournalLevel.allCases), items: rows, feedback: []).build().text
        #expect(digest.contains("about 09:00") && digest.contains("about 5 min"))
        let writer = try #require(f.folder)
        let paths = await writer.recordReflection(id: "reflection", text: .init(digest), at: f.clock.now)
        let path = try #require(paths.first), root = try #require(writer.folderURL)
        #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == digest + "\n\n")
    }
    @Test func reflectionFeedbackRedactsSentencesWithoutTouchingGeneratedDates() async throws {
        let f = try LearningRuntimeFixture(redactor: DestructiveFactRedactor(), calendar: ReflectionPatternTests.calendar)
        defer { f.stop() }
        let (day, rows) = ReflectionPatternTests.fixture()
        f.clock.now = day.addingTimeInterval(20 * 3600); f.connector.available = false
        for row in rows { try f.journal.append(row) }
        let rule = try f.rules.addOwn(.init(sentence: "Notify alex@example.test at 08:41"), at: f.clock.now)
        try f.rules.setStatus(.retired, id: rule.id, at: f.clock.now)
        f.box.enabled = true; f.box.context.idleSince = f.clock.now.addingTimeInterval(-601)
        f.runtime.learningContextDidChange()
        try await eventually { f.runtime.ledger?.records.contains { $0.delivery.kind == .reflection } == true }
        let reflection = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .reflection }?.delivery.content)
        #expect(reflection.contains("Rule outcomes since the last reflection"))
        #expect(reflection.contains("“‹secret›”"))
        #expect(!reflection.contains("alex@example.test"))
        let local = ReflectionLocalTime(calendar: ReflectionPatternTests.calendar)
        #expect(reflection.contains(local.label(f.clock.now)))
        let until = try #require((f.rules as any RuleLifecycleStoring).suppressedRules.first?.until)
        #expect(reflection.contains("until " + local.label(until, "d MMM")))
    }
    @Test func rulesAndPreferencesRedactRawDetailsButKeepClockFacts() async throws {
        let f = try LearningRuntimeFixture(redactor: LocalRedactor(useOnDeviceModel: false), exportFolder: true)
        defer { f.stop() }
        let rule = "At 08:41 allow 17 min for mail to alex@example.test."
        _ = try f.rules.addOwn(.init(sentence: rule), at: f.clock.now)
        let writer = try #require(f.folder)
        await writer.flush()
        let root = try #require(writer.folderURL)
        let text = try String(contentsOf: root.appendingPathComponent("Zeus/rules.md"), encoding: .utf8)
        #expect(text.contains("08:41") && text.contains("17 min"))
        #expect(!text.contains("alex@example.test"))
        let example = LocalRedactor.firstPass("At 08:41, review for 17 min with alex@example.test.").value
        let rating = MessageRating(id: "r", kindLabel: "Morning planning", kindKey: "morning planning", rating: .up,
            scope: .kind, exampleCardID: "c", exampleText: example, createdAt: f.clock.now, updatedAt: f.clock.now)
        _ = await writer.recordRatings([rating])
        let preferences = try String(contentsOf: root.appendingPathComponent("Zeus/preferences.md"), encoding: .utf8)
        #expect(preferences.contains(example) && preferences.contains("08:41") && preferences.contains("17 min"))
        #expect(!preferences.contains("alex@example.test"))
    }
}

private struct DestructiveFactRedactor: Redactor {
    func redact(_ text: String) async -> Redacted<String> { .init("‹secret›") }
}
