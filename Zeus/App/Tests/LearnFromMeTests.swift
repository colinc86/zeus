import Foundation
import Testing
@testable import Zeus

// L1 "Learn from me" (CONTRACT §13). Every test uses a fake event source, a UTC calendar, its own temporary Activity
// folder and UserDefaults suite. Nothing observes the real workspace or touches the real Activity folder.

@MainActor private final class FakeActivitySource: ActivityEventSource {
    var handler: (@MainActor (ActivitySignal) -> Void)?
    var secondsSinceLastInput: TimeInterval = 0
    var frontmostApp: (bundleID: String?, name: String?)? = ("com.apple.finder", "Finder")
    var displayCount = 1
    func start(_ handler: @escaping @MainActor (ActivitySignal) -> Void) { self.handler = handler }
    func stop() { handler = nil }
    func send(_ signal: ActivitySignal) { handler?(signal) }
}

@MainActor private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()
private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text) ?? .distantPast }
private var fixtures: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("TestFixtures/learn", isDirectory: true)
}

@MainActor private final class LearnFixture {
    let suite = TestDefaults.suite("zeus-l1")
    let defaults: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-l1-\(UUID())/Activity", isDirectory: true)
    let clock: Clock
    let source = FakeActivitySource()
    let learn: LearnFromMe
    var recorded: [Learning] = []
    var notified: [Learning] = []

    init(now: Date, seedFixtures: Bool = false) throws {
        defaults = UserDefaults(suiteName: suite) ?? .standard
        clock = Clock(now)
        if seedFixtures {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
                try FileManager.default.copyItem(at: file, to: root.appendingPathComponent(file.lastPathComponent))
            }
        }
        let clock = clock, source = source
        learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: root, calendar: utc, clock: { clock.now }, source: { source })
        learn.learnings?.onRecorded = { [unowned self] in recorded.append($0) }
        learn.learnings?.onNewLearning = { [unowned self] in notified.append($0) }
    }
    func cleanup() {
        learn.stop()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: suite)
    }
    var store: ActivityStore { ActivityStore(root: root, calendar: utc) }
}

@MainActor @Suite(.serialized) struct LearningSummarizerTests {
    private var store: ActivityStore { ActivityStore(root: fixtures, calendar: utc) }
    private var previousStarts: [Date] {
        ["2026-10-07", "2026-10-08", "2026-10-09"].compactMap {
            LearningSummarizer.stats(store.events(on: at($0 + "T12:00:00Z")), excluded: ExcludedApp.defaults).firstActivity
        }
    }

    @Test func digestOfAFixtureDay() throws {
        let day = at("2026-10-12T00:00:00Z")
        let digest = try #require(LearningSummarizer.digest(day: day, events: store.events(on: day), previousStarts: previousStarts,
                                                            excluded: ExcludedApp.defaults, calendar: utc))
        #expect(digest == """
        Zeus's summary of Monday, October 12 (app usage and timing only):
        - Active 08:42–18:10, about 8 h 43 min at the Mac.
        - Lunch gap 12:05–12:50.
        - First app: Things at 08:44.
        - Top apps: Xcode 6 h 29 min, Safari 1 h 10 min, Mail 35 min, Things 12 min.
        - Private time: 15 min in apps you keep private.
        - Started 17 min later than usual (08:25, the median of the last 4 weeks).
        """)
        #expect(digest.split(separator: "\n").count <= 10)
    }

    @Test func digestNeverNamesAnExcludedApp() throws {
        let day = at("2026-10-12T00:00:00Z")
        // Keychain Access was recorded by name before it was excluded; Safari is excluded now.
        let excluded = ExcludedApp.defaults + [ExcludedApp(name: "Safari", bundleIDs: ["com.apple.Safari"])]
        let digest = try #require(LearningSummarizer.digest(day: day, events: store.events(on: day), previousStarts: [],
                                                            excluded: excluded, calendar: utc))
        for app in excluded { #expect(!digest.localizedCaseInsensitiveContains(app.name), "\(app.name)") }
        #expect(digest.contains("Private time: 1 h 25 min") && digest.contains("Not enough days yet"))
    }

    @Test func momentsForFirstActivityLateStartBreakAndWindingDown() {
        let first = ActivityEvent(t: at("2026-10-13T09:40:00Z"), kind: .unlock)
        let found = LearningSummarizer.moments(after: first, earlier: [], medianStart: 8 * 60 + 25, calendar: utc)
        #expect(found.map(\.kind) == [.firstActivity, .lateStart])
        #expect(found.last?.text == "Later start than usual: first activity at 09:40, 1 h 15 min after the usual 08:25.")
        #expect(LearningSummarizer.moments(after: first, earlier: [], medianStart: 9 * 60, calendar: utc).map(\.kind) == [.firstActivity])

        let morning = [first, ActivityEvent(t: at("2026-10-13T11:00:00Z"), kind: .lock)]
        let back = ActivityEvent(t: at("2026-10-13T13:30:00Z"), kind: .unlock)
        #expect(LearningSummarizer.moments(after: back, earlier: morning, medianStart: nil, calendar: utc)
                == [Moment(kind: .backFromBreak, text: "Back at the Mac at 13:30 after 2 h 30 min away.")])
        let soon = ActivityEvent(t: at("2026-10-13T12:00:00Z"), kind: .unlock)
        #expect(LearningSummarizer.moments(after: soon, earlier: morning, medianStart: nil, calendar: utc).isEmpty)

        #expect(LearningSummarizer.windingDown(idleSince: at("2026-10-13T17:40:00Z"), now: at("2026-10-13T18:00:00Z"), calendar: utc)?.text
                == "Day winding down: no input since 17:40.")
        #expect(LearningSummarizer.windingDown(idleSince: at("2026-10-13T16:50:00Z"), now: at("2026-10-13T18:00:00Z"), calendar: utc) == nil)
        #expect(LearningSummarizer.windingDown(idleSince: at("2026-10-13T17:50:00Z"), now: at("2026-10-13T18:00:00Z"), calendar: utc) == nil)
    }

    @Test func momentsAreRateLimitedAndOnlyTickedKinds() {
        let all = Set(MomentKind.allCases)
        let breaks = (0..<6).map { Moment(kind: .backFromBreak, text: "\($0)") }
        #expect(LearningSummarizer.gate(breaks, ticked: all, sentToday: []).count == 4)
        #expect(LearningSummarizer.gate(breaks, ticked: all, sentToday: [.firstActivity, .lateStart, .backFromBreak]).count == 1)
        let first = Moment(kind: .firstActivity, text: "x")
        #expect(LearningSummarizer.gate([first], ticked: all, sentToday: [.firstActivity]).isEmpty, "once a day")
        #expect(LearningSummarizer.gate([first, breaks[0]], ticked: [.backFromBreak], sentToday: []).map(\.kind) == [.backFromBreak])
    }
}

@MainActor @Suite(.serialized) struct ActivityRecorderTests {
    private func recorder(_ source: FakeActivitySource, paused: @escaping (Date) -> Bool = { _ in false }) -> (ActivityRecorder, () -> [ActivityEvent]) {
        var events: [ActivityEvent] = []
        let excluded = ExcludedApp.defaults
        let recorder = ActivityRecorder(source: source, isExcluded: { id, name in excluded.contains { $0.matches(bundleID: id, name: name) } },
                                        isPaused: paused, clock: { at("2026-10-13T09:00:00Z") }) { events.append($0) }
        return (recorder, { events })
    }

    @Test func excludedAppsBecomePrivateTimeWithNoName() {
        let source = FakeActivitySource()
        let (recorder, events) = recorder(source)
        recorder.start()
        recorder.receive(.launched(bundleID: "com.1password.1password", name: "1Password"), at: at("2026-10-13T09:01:00Z"))
        recorder.receive(.activated(bundleID: "com.1password.1password", name: "1Password"), at: at("2026-10-13T09:01:00Z"))
        recorder.receive(.activated(bundleID: "com.apple.dt.Xcode", name: "Xcode"), at: at("2026-10-13T09:03:00Z"))
        recorder.receive(.quit(bundleID: "com.1password.1password", name: "1Password"), at: at("2026-10-13T09:04:00Z"))
        #expect(events().map(\.kind) == [.displays, .activate, .private, .activate])
        let secret = events()[2]
        #expect(secret.t == at("2026-10-13T09:01:00Z") && secret.seconds == 120 && secret.app == nil && secret.name == nil)
        let written = String(decoding: (try? ActivityStore.encoder.encode(events().map { $0 })) ?? Data(), as: UTF8.self)
        #expect(!written.contains("1Password") && !written.contains("1password"))
    }

    @Test func idlePollStartsAndEndsAnIdlePeriod() {
        let source = FakeActivitySource()
        let (recorder, events) = recorder(source)
        recorder.start()
        source.secondsSinceLastInput = 299
        recorder.tick(now: at("2026-10-13T10:00:00Z"))
        #expect(recorder.idleSince == nil)
        source.secondsSinceLastInput = 360
        recorder.tick(now: at("2026-10-13T10:00:00Z"))
        recorder.tick(now: at("2026-10-13T10:01:00Z"))
        #expect(recorder.idleSince == at("2026-10-13T09:54:00Z"))
        source.secondsSinceLastInput = 2
        recorder.tick(now: at("2026-10-13T10:30:00Z"))
        #expect(events().filter { $0.kind == .idle || $0.kind == .active }
                == [ActivityEvent(t: at("2026-10-13T09:54:00Z"), kind: .idle), ActivityEvent(t: at("2026-10-13T10:29:58Z"), kind: .active)])
    }

    @Test func signalsFromTheSourceAreRecordedAndStopEndsThem() {
        let source = FakeActivitySource()
        let (recorder, events) = recorder(source)
        recorder.start()
        source.send(.locked)
        source.send(.unlocked)
        recorder.stop()
        source.send(.locked)
        #expect(events().map(\.kind) == [.displays, .activate, .lock, .unlock])
        #expect(source.handler == nil)
    }

    @Test func pausedDropsEvents() {
        let source = FakeActivitySource()
        let (recorder, events) = recorder(source, paused: { _ in true })
        recorder.start()
        source.send(.activated(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
        source.secondsSinceLastInput = 900
        recorder.tick(now: at("2026-10-13T10:00:00Z"))
        #expect(events().isEmpty)
    }
}

@MainActor @Suite(.serialized) struct LearnFromMeTests {
    @Test func offByDefaultAndNothingIsWritten() throws {
        let f = try LearnFixture(now: at("2026-10-13T09:00:00Z")); defer { f.cleanup() }
        f.learn.start()
        #expect(!f.learn.settings.enabled && !f.learn.isRecording && f.source.handler == nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.path))
        #expect(f.learn.learnings?.learningsEnabled == false)
    }

    @Test func morningDigestAndMomentsReachTheSeamAndTheThread() throws {
        let f = try LearnFixture(now: at("2026-10-13T08:30:00Z"), seedFixtures: true); defer { f.cleanup() }
        f.learn.start()
        f.learn.setEnabled(true)
        f.source.send(.unlocked)
        let seam: any LearningsProviding = try #require(f.learn.learnings)
        let unread = seam.unreadLearnings()
        #expect(unread.map(\.kind) == [.digest, .moment])
        #expect(unread.first?.text.hasPrefix("Zeus's summary of Monday, October 12") == true)
        #expect(unread.last?.text == "First activity today at 08:30.")
        #expect(f.recorded == unread && f.notified == unread)
        #expect(ThreadNotice.learning(unread[0]).summary == "Sent the morning summary")
        #expect(ThreadNotice.learning(unread[1]).summary == "Sent a note: first activity today")
        #expect(ThreadNotice.learning(unread[0]).detail == unread[0].text)

        seam.markLearningsRead(through: unread[0].id)
        #expect(seam.unreadLearnings() == [unread[1]])
        // Once a day: another unlock sends neither again.
        f.source.send(.locked)
        f.source.send(.unlocked)
        #expect(seam.unreadLearnings().count == 1)
        // Off: the assistant gets nothing.
        f.learn.setEnabled(false)
        #expect(seam.unreadLearnings().isEmpty && f.source.handler == nil)
    }

    @Test func pauseForTodayDropsEventsUntilTomorrow() throws {
        let f = try LearnFixture(now: at("2026-10-13T09:00:00Z")); defer { f.cleanup() }
        f.learn.setEnabled(true)
        let before = f.learn.today.count
        f.learn.pauseForToday()
        #expect(f.learn.settings.pausedUntil == at("2026-10-14T00:00:00Z") && f.learn.isPausedNow)
        f.source.send(.activated(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
        f.source.send(.locked)
        #expect(f.store.events(on: f.clock.now).count == before)
        f.clock.now = at("2026-10-14T08:00:00Z")
        f.source.send(.unlocked)
        #expect(f.store.events(on: f.clock.now).map(\.kind) == [.unlock])
    }

    @Test func filesArePrivateToTheUser() throws {
        let f = try LearnFixture(now: at("2026-10-13T09:00:00Z")); defer { f.cleanup() }
        f.learn.setEnabled(true)
        f.source.send(.unlocked)
        func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1 }
        #expect(mode(f.root) == 0o700)
        #expect(mode(f.root.appendingPathComponent("2026-10-13.jsonl")) == 0o600)
        #expect(mode(f.root.appendingPathComponent(LearningsStore.fileName)) == 0o600)
    }

    @Test func retentionPrunesRawDaysAndYearOldLearnings() throws {
        let f = try LearnFixture(now: at("2026-10-13T09:00:00Z")); defer { f.cleanup() }
        let store = f.store
        for day in ["2026-10-08", "2026-09-13", "2026-09-12", "2026-08-01"] {
            try store.append(ActivityEvent(t: at(day + "T09:00:00Z"), kind: .unlock))
        }
        f.learn.settings.retentionDays = 30
        f.learn.learnings?.add(.digest, text: "old", at: at("2025-10-01T09:00:00Z"))
        f.learn.learnings?.add(.digest, text: "recent", at: at("2026-10-01T09:00:00Z"))
        f.learn.start()
        #expect(store.recordedDays().map(store.dayKey) == ["2026-09-13", "2026-10-08"])
        #expect(f.learn.learnings?.learnings.map(\.text) == ["recent"])
        f.learn.settings.retentionDays = 400
        #expect(f.learn.settings.retentionDays == 90)
        f.learn.settings.retentionDays = 1
        #expect(f.learn.settings.retentionDays == 7)
    }

    @Test func deleteEverythingEmptiesTheFolderAndTheSummaries() throws {
        let f = try LearnFixture(now: at("2026-10-13T08:30:00Z"), seedFixtures: true); defer { f.cleanup() }
        var cleared = false
        f.learn.onDeleteEverything = { cleared = true }
        f.learn.setEnabled(true)
        f.source.send(.unlocked)
        #expect(f.learn.learnings?.unreadLearnings().isEmpty == false)
        f.learn.deleteEverything()
        #expect(cleared && f.learn.today.isEmpty && f.learn.learnings?.learnings.isEmpty == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.root.path)) ?? []).isEmpty)
    }

    @Test func settingsPersistWithDefaults() throws {
        let f = try LearnFixture(now: at("2026-10-13T09:00:00Z")); defer { f.cleanup() }
        let settings = f.learn.settings
        #expect(settings.excludedApps.map(\.name) == ["1Password", "Bitwarden", "KeePassXC", "Strongbox", "Enpass", "Dashlane",
                                                      "Keychain Access", "Passwords", "System Settings"])
        settings.excludedApps.append(ExcludedApp(name: "Notes", bundleIDs: ["com.apple.Notes"]))
        settings.momentKinds = [.firstActivity]
        let again = LearnSettings(defaults: f.defaults)
        #expect(again.excludedApps.last?.name == "Notes" && again.momentKinds == [.firstActivity])
        #expect(again.isExcluded(bundleID: "COM.APPLE.NOTES", name: nil) && again.isExcluded(bundleID: nil, name: "notes"))
    }

    /// PERF2: the idle poll runs every 30 s or less often, stops while the Mac is locked or asleep, and resumes after.
    @Test func idlePollSuspendsWhileLockedOrAsleep() throws {
        let f = try LearnFixture(now: at("2026-10-13T09:00:00Z")); defer { f.cleanup() }
        #expect(LearnFromMe.tickInterval >= .seconds(30))
        f.learn.settings.introShown = true
        f.learn.setEnabled(true)
        #expect(f.learn.isRecording && f.learn.isTicking)
        f.source.send(.locked)
        #expect(!f.learn.isTicking)
        f.source.send(.unlocked)
        #expect(f.learn.isTicking)
        f.source.send(.sleep)
        #expect(!f.learn.isTicking)
        f.source.send(.wake)
        #expect(f.learn.isTicking)
        f.source.send(.locked)
        f.learn.setEnabled(false)
        #expect(!f.learn.isRecording && !f.learn.isTicking, "stopping while locked never restarts the poll")
    }

    /// PERF2: today's list is kept in memory per event, in the same order the store reads back.
    @Test func todayStaysInStoreOrderWithoutRereading() throws {
        let f = try LearnFixture(now: at("2026-10-13T11:00:00Z")); defer { f.cleanup() }
        f.learn.settings.introShown = true
        f.learn.setEnabled(true)
        f.source.send(.activated(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
        f.learn.record(ActivityEvent(t: at("2026-10-13T10:40:00Z"), kind: .idle))
        f.clock.now = at("2026-10-13T11:05:00Z")
        f.source.send(.activated(bundleID: "com.apple.Safari", name: "Safari"))
        #expect(f.learn.today == f.store.events(on: f.clock.now))
        #expect(f.learn.today.map(\.t) == f.learn.today.map(\.t).sorted())
    }

    @Test func shellTestsWithoutAFolderNeverRecord() {
        let learn = LearnFromMe(settings: LearnSettings(defaults: UserDefaults(suiteName: TestDefaults.suite("zeus-l1-none")) ?? .standard), root: nil)
        learn.setEnabled(true)
        #expect(!learn.isAvailable && !learn.isRecording && learn.learnings == nil)
    }
}
