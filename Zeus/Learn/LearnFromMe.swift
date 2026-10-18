import Foundation
import Observation

/// "Learn from me", level 1 (CONTRACT §13): ties the recorder, the raw store, the summarizer and the learnings
/// together, and is what Settings › Privacy shows. Off by default; records only while the switch is on.
@MainActor
@Observable
final class LearnFromMe {
    let settings: LearnSettings
    /// Nil when there's no Activity folder (tests that pass no folder); the switch then can't be turned on.
    @ObservationIgnored let files: ActivityStore?
    let learnings: LearningsStore?
    /// Today's raw events for "What Zeus has recorded".
    private(set) var today: [ActivityEvent] = []
    private(set) var writeError: String?
    @ObservationIgnored private let makeSource: () -> any ActivityEventSource
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let journal: (any JournalStore)?
    @ObservationIgnored private let redactor: (any Redactor)?
    @ObservationIgnored var outboundPolicy: () -> LearningOutboundPolicy? = { nil }
    @ObservationIgnored private let captureAllowed: (ActivityEvent) -> Bool
    @ObservationIgnored private var captureGeneration = UUID()
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var migrationTask: Task<Void, Never>?
    @ObservationIgnored private var recorder: ActivityRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastTickDay: String?
    @ObservationIgnored private var startCache: [String: Date?] = [:]
    /// How often the idle poll runs while recording; it's suspended while the Mac is locked or asleep (PERF2).
    static let tickInterval: Duration = .seconds(30)
    /// Whether the idle poll is scheduled: recording, and the Mac is neither locked nor asleep.
    var isTicking: Bool { ticker != nil }
    /// Set by the app: "Delete everything" also removes the summaries' thread lines.
    @ObservationIgnored var onDeleteEverything: (() -> Void)?

    init(settings: LearnSettings, root: URL?, calendar: Calendar = .current, clock: @escaping () -> Date = Date.init,
         source: @escaping () -> any ActivityEventSource = { WorkspaceActivitySource() },
         journal: (any JournalStore)? = nil, redactor: (any Redactor)? = nil,
         captureAllowed: @escaping (ActivityEvent) -> Bool = { _ in true }) {
        self.journal = journal; self.redactor = redactor; self.captureAllowed = captureAllowed
        self.settings = settings
        self.calendar = calendar
        self.clock = clock
        makeSource = source
        let files = root.map { ActivityStore(root: $0, calendar: calendar, journal: journal) }
        self.files = files
        learnings = files.map { files in LearningsStore(files: files, isEnabled: { [weak settings] in settings?.enabled ?? false }) }
        learnings?.currentDigestPolicy = { [weak self] in self?.digestPolicyKey ?? "unavailable" }
        learnings?.rebuildDigest = { [weak self] day, created in self?.digestText(day: day, createdAt: created) }
        learnings?.legacyDigestDay = { [weak self] created in
            self?.files?.recordedDays().last(where: { $0 < (self?.calendar.startOfDay(for: created) ?? created) })
        }
    }

    var isAvailable: Bool { files != nil }
    var isRecording: Bool { recorder?.isRunning ?? false }
    var isPausedNow: Bool { settings.isPaused(at: clock()) }

    /// App launch: prune old files, then record if the switch is on.
    func start() {
        prune()
        startLegacyMigration()
        if settings.enabled { startRecording() }
        refreshToday()
    }
    private func startLegacyMigration() {
        if migrationTask == nil, let files, files.hasLegacyActivity, let redactor, journal != nil, settings.enabled {
            let token = captureGeneration
            migrationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await files.migrateLegacy(redactor: redactor,
                        allowed: { [weak self] event in self?.mayCapture(event) ?? false },
                        excluded: { [weak self] event in
                            guard let self else { return false }
                            return event.app != nil && settings.isExcluded(bundleID: event.app, name: event.name)
                        },
                        stillAllowed: { [weak self] in self?.captureGeneration == token && self?.settings.enabled == true })
                    guard captureGeneration == token else { return }; migrationTask = nil; refreshToday()
                } catch { migrationTask = nil; writeError = "Zeus couldn't finish migrating old activity. Unprocessed files are unchanged." }
            }
        }
    }
    func stop() {
        invalidatePendingCapture()
        stopTicker()
        recorder?.stop()
        recorder = nil
    }

    /// The switch. Turning it off stops recording and keeps what's stored until it ages out or is deleted.
    func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        settings.enabled = on
        if on { startRecording() } else { stop() }
    }

    func pauseForToday() {
        invalidatePendingCapture()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock())) ?? clock().addingTimeInterval(86_400)
        settings.pausedUntil = tomorrow
    }
    func resume() { settings.pausedUntil = nil }

    /// Removes every raw event and summary. Recording continues if the switch is on.
    func deleteEverything() {
        invalidatePendingCapture()
        files?.deleteEverything()
        learnings?.reset()
        startCache.removeAll()
        today = []
        onDeleteEverything?()
    }

    func refreshToday() { today = files?.events(on: clock()) ?? [] }

    /// The idle poll, the "winding down" check and the midnight prune. The app calls it every 30 s while recording.
    func tick(now: Date? = nil) {
        let now = now ?? clock()
        recorder?.tick(now: now)
        startLegacyMigration()
        if let files {
            let day = files.dayKey(now)
            if let lastTickDay, lastTickDay != day { prune(); refreshToday() }
            lastTickDay = day
        }
        if let idleSince = recorder?.idleSince, let moment = LearningSummarizer.windingDown(idleSince: idleSince, now: now, calendar: calendar) {
            send([moment], at: now)
        }
    }

    /// Writes one event, then makes any digest or moments it triggers.
    func record(_ event: ActivityEvent) {
        guard let files else { return }
        guard journal != nil else { commit(event, write: { try files.append(event) }); return }
        guard let redactor, mayCapture(event) else { return }
        let token = captureGeneration, previous = captureTask
        captureTask = Task { [weak self] in
            await previous?.value
            guard let self, token == captureGeneration, mayCapture(event), !Task.isCancelled else { return }
            let safe = await redactor.redact(ActivityStore.payload(event))
            // No suspension between the final policy/generation check and the encrypted append.
            guard token == captureGeneration, mayCapture(event), !Task.isCancelled else { return }
            let item = JournalItem(time: event.t, level: .activity, app: event.app, kind: .activity, payload: safe)
            guard let safeEvent = ActivityStore.activityEvent(item) else { return }
            commit(safeEvent, write: { try files.appendRedacted(safe, event: safeEvent) })
        }
    }
    /// App calls on capture policy/context changes and before journal deletion. Invalidates any redaction in flight.
    func invalidatePendingCapture() {
        captureGeneration = UUID(); captureTask?.cancel(); captureTask = nil
        migrationTask?.cancel(); migrationTask = nil
    }
    /// App calls after boundary invalidation when capture remains enabled; this is a fresh observation, not replay.
    func captureCurrentActivity() { recorder?.captureCurrentApp() }
    private func mayCapture(_ event: ActivityEvent) -> Bool {
        settings.enabled && !settings.isPaused(at: clock()) && captureAllowed(event) &&
        (event.app == nil || !settings.isExcluded(bundleID: event.app, name: event.name))
    }
    private func commit(_ event: ActivityEvent, write: () throws -> Void) {
        guard let files else { return }
        let earlier = calendar.isDate(event.t, inSameDayAs: clock()) && !today.isEmpty ? today : files.events(on: event.t)
        do { try write(); writeError = nil } catch {
            writeError = "Zeus couldn't save today's activity. \(error.localizedDescription)"
            return
        }
        // Keep today's list in memory, in the store's time order, instead of re-reading the day's file per event (PERF2).
        if calendar.isDate(event.t, inSameDayAs: clock()) {
            today.insert(event, at: today.lastIndex { $0.t <= event.t }.map { $0 + 1 } ?? 0)
        }
        guard event.showsPresence, migrationTask == nil else { return }
        sendDigestIfDue(now: event.t)
        let median = LearningSummarizer.medianStart(previousStarts(before: event.t), calendar: calendar)
        send(LearningSummarizer.moments(after: event, earlier: earlier, medianStart: median, calendar: calendar), at: event.t)
    }

    /// Morning-of: at the first activity of a new day, summarize the most recent earlier day not yet summarized.
    func sendDigestIfDue(now: Date) {
        guard let files, let learnings else { return }
        let todayStart = calendar.startOfDay(for: now)
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: todayStart) else { return }
        let pending = files.recordedDays().filter { $0 < todayStart && $0 >= weekAgo && !learnings.isDigested(files.dayKey($0)) }
        guard let day = pending.last else { return }
        learnings.markDigested(pending.map(files.dayKey))
        guard let text = digestText(day: day, createdAt: now) else { return }
        learnings.addDigest(text: text, at: now, day: day, policy: digestPolicyKey)
    }

    private var digestPolicyKey: String {
        if let policy = outboundPolicy() { return policy.fingerprint }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "activity:" + String(decoding: (try? encoder.encode(settings.excludedApps)) ?? Data(), as: UTF8.self)
    }
    private func digestText(day: Date, createdAt: Date) -> String? {
        guard let files else { return nil }
        let policy = outboundPolicy()
        startCache.removeAll()
        let events = files.events(on: day)
        guard var text = LearningSummarizer.digest(day: day, events: events, previousStarts: previousStarts(before: day),
                                                    excluded: digestExclusions(events), calendar: calendar) else { return nil }
        if let journal, let policy {
            var query = JournalQuery(); query.from = calendar.startOfDay(for: day)
            query.to = calendar.date(byAdding: .day, value: 1, to: query.from ?? day)
            query.levels = [.screen]; query.kinds = [.description]; query.limit = 100_000
            do {
                let sample = Self.screenSummary(try journal.items(matching: query).filter(policy.allows))
                if !sample.isEmpty { text += "\n- On screen: " + sample }
                query.levels = [.typed]; query.kinds = [.typedText]
                let topics = Self.typingSummary(try journal.items(matching: query).filter(policy.allows))
                if !topics.isEmpty { text += "\n- Typing: " + topics }
            } catch { writeError = "Zeus couldn't read the journal for its summary."; return nil }
        }
        return text
    }

    /// Retain transition boundaries: removing an activation would attribute its private interval to the preceding app.
    private func digestExclusions(_ events: [ActivityEvent]) -> [ExcludedApp] {
        let policy = outboundPolicy()
        return settings.excludedApps + events.compactMap { event in
            guard let app = event.app, settings.isExcluded(bundleID: app, name: event.name)
                    || policy?.allows(level: .activity, app: app, name: event.name) == false else { return nil }
            return ExcludedApp(name: event.name ?? app, bundleIDs: [app])
        }
    }

    /// Deterministic, evenly spaced description sampling; no image or OCR text reaches a summary.
    static func screenSummary(_ descriptions: [JournalItem]) -> String {
        let rows = descriptions.filter { $0.level == .screen && $0.kind == .description }
        let indices = rows.count <= 4 ? Array(rows.indices) : (0..<4).map { $0 * (rows.count - 1) / 3 }
        return indices.map { String(rows[$0].payload.value.description.prefix(240)) }.joined(separator: " · ")
    }
    /// Never substitute text/description for a missing topic: IME counts and local words stay on the Mac.
    static func typingSummary(_ items: [JournalItem]) -> String {
        let topics = items.filter { $0.level == .typed && $0.kind == .typedText }.compactMap { $0.payload.value.topic }
        let indices = topics.count <= 4 ? Array(topics.indices) : (0..<4).map { $0 * (topics.count - 1) / 3 }
        return indices.map { String(topics[$0].prefix(240)) }.joined(separator: " · ")
    }

    private func send(_ moments: [Moment], at date: Date) {
        guard let files, let learnings else { return }
        let key = files.dayKey(date)
        for moment in LearningSummarizer.gate(moments, ticked: settings.momentKinds, sentToday: learnings.momentsSent(on: key)) {
            learnings.add(.moment, text: moment.text, at: date, moment: moment.kind, dayKey: key)
        }
    }

    /// First activity of each of the 28 days before `date`, for the usual start time.
    private func previousStarts(before date: Date) -> [Date] {
        guard let files else { return [] }
        let start = calendar.startOfDay(for: date)
        guard let from = calendar.date(byAdding: .day, value: -28, to: start) else { return [] }
        return files.recordedDays().filter { $0 >= from && $0 < start }.compactMap { day in
            let key = files.dayKey(day)
            if let cached = startCache[key] { return cached }
            let events = files.events(on: day)
            let first = LearningSummarizer.stats(events, excluded: digestExclusions(events)).firstActivity
            startCache[key] = first
            return first
        }
    }

    private func prune() {
        if journal == nil { files?.prune(now: clock(), keepingDays: settings.retentionDays) }
        learnings?.prune(now: clock(), calendar: calendar)
        startCache.removeAll()
    }

    private func startRecording() {
        guard recorder == nil, isAvailable else { return }
        let recorder = ActivityRecorder(source: makeSource(),
                                        isExcluded: { [weak settings] in settings?.isExcluded(bundleID: $0, name: $1) ?? true },
                                        isPaused: { [weak settings] in settings?.isPaused(at: $0) ?? true },
                                        clock: clock) { [weak self] in self?.record($0) }
        self.recorder = recorder
        recorder.onSuspendedChange = { [weak self] suspended in
            // Stopping the recorder also clears its lock state; only a running recorder resumes the poll.
            guard let self, isRecording else { return }
            if suspended { stopTicker() } else { tick(); startTicker() }
        }
        recorder.start()
        startTicker()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.tickInterval) } catch { return }
                self?.tick()
            }
        }
    }
    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}

extension LearnFromMe {
    /// The thread line for a learning: "Sent the morning summary", or "Sent a note: back from a break".
    nonisolated static func noticeSummary(_ learning: Learning) -> String {
        guard learning.kind == .moment else { return "Sent the morning summary" }
        let kind = MomentKind.allCases.first { learning.text.hasPrefix(momentPrefix($0)) }
        return kind.map { "Sent a note: \($0.noticeName)" } ?? "Sent a note"
    }
    nonisolated private static func momentPrefix(_ kind: MomentKind) -> String {
        switch kind {
        case .firstActivity: "First activity today"
        case .backFromBreak: "Back at the Mac"
        case .lateStart: "Later start than usual"
        case .windingDown: "Day winding down"
        }
    }
}

extension ThreadNotice {
    /// The thread line for a learning, with "View" showing the exact text the assistant receives.
    static func learning(_ learning: Learning) -> ThreadNotice {
        ThreadNotice(id: "n_" + learning.id, kind: .learning, createdAt: learning.createdAt,
                     summary: LearnFromMe.noticeSummary(learning), actionTitle: "View", detail: learning.text,
                     deliveryKindName: LearningDeliveryVocabulary.title(kind: learning.kind.rawValue))
    }
}
