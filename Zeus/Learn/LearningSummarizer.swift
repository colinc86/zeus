import Foundation

/// The kinds of "moment" the user can tick in Settings › Privacy (CONTRACT §13).
enum MomentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case firstActivity, backFromBreak, lateStart, windingDown
    var id: String { rawValue }
    /// The checkbox label.
    var title: String {
        switch self {
        case .firstActivity: "First activity of the day"
        case .backFromBreak: "Back from a break of 2 hours or more"
        case .lateStart: "A later start than usual"
        case .windingDown: "Day winding down (no input for 20 min after 17:00)"
        }
    }
    /// The thread line's words: "Sent a note: back from a break".
    var noticeName: String {
        switch self {
        case .firstActivity: "first activity today"
        case .backFromBreak: "back from a break"
        case .lateStart: "a later start"
        case .windingDown: "day winding down"
        }
    }
}

/// A moment the summarizer found; the gate decides whether it is sent.
struct Moment: Equatable, Sendable {
    let kind: MomentKind
    let text: String
}

/// What one day looked like, from its raw events.
struct DayStats: Equatable, Sendable {
    var firstActivity: Date?
    var lastActivity: Date?
    /// Idle, locked or asleep, in time order.
    var away: [DateInterval] = []
    /// Seconds per app name, excluded apps left out.
    var appSeconds: [String: Double] = [:]
    var firstApp: (name: String, at: Date)?
    var privateSeconds: Double = 0
    /// The span from first to last activity, less the time away.
    var activeSeconds: Double {
        guard let first = firstActivity, let last = lastActivity, last > first else { return 0 }
        let span = DateInterval(start: first, end: last)
        return span.duration - away.reduce(0) { $0 + ($1.intersection(with: span)?.duration ?? 0) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.firstActivity == rhs.firstActivity && lhs.lastActivity == rhs.lastActivity && lhs.away == rhs.away
            && lhs.appSeconds == rhs.appSeconds && lhs.firstApp?.name == rhs.firstApp?.name && lhs.firstApp?.at == rhs.firstApp?.at
            && lhs.privateSeconds == rhs.privateSeconds
    }
}

/// Turns raw events into the morning digest and moments. Pure functions: everything they need is passed in, so the
/// tests run on fixture days. Nothing here ever names an excluded app.
enum LearningSummarizer {
    static let maxMomentsPerDay = 4
    static let breakForMoment: TimeInterval = 2 * 3600
    static let lateStartMargin = 45
    static let windingDownIdle: TimeInterval = 20 * 60
    static let windingDownAfterMinute = 17 * 60

    // MARK: Stats

    static func stats(_ events: [ActivityEvent], excluded: [ExcludedApp]) -> DayStats {
        var stats = DayStats()
        var current: (name: String, isPrivate: Bool)?
        var segmentStart: Date?
        var awayStart: Date?

        func present(_ t: Date) {
            if stats.firstActivity == nil { stats.firstActivity = t }
            stats.lastActivity = max(stats.lastActivity ?? t, t)
        }
        func close(_ t: Date) {
            if let start = segmentStart, let app = current, t > start {
                if app.isPrivate { stats.privateSeconds += t.timeIntervalSince(start) }
                else { stats.appSeconds[app.name, default: 0] += t.timeIntervalSince(start) }
            }
            segmentStart = nil
        }
        func back(_ t: Date) {
            if let start = awayStart, t > start { stats.away.append(DateInterval(start: start, end: t)) }
            awayStart = nil
        }

        for event in events {
            switch event.kind {
            case .activate:
                close(event.t)
                back(event.t)
                let isPrivate = isExcluded(event, excluded)
                current = (event.appName, isPrivate)
                segmentStart = event.t
                present(event.t)
                if stats.firstApp == nil && !isPrivate { stats.firstApp = (event.appName, event.t) }
            case .private:
                close(event.t)
                back(event.t)
                current = nil
                let seconds = max(0, event.seconds ?? 0)
                stats.privateSeconds += seconds
                present(event.t)
                present(event.t.addingTimeInterval(seconds))
            case .idle, .lock, .sleep:
                guard awayStart == nil else { continue }
                close(event.t)
                awayStart = event.t
                if stats.firstActivity != nil { stats.lastActivity = max(stats.lastActivity ?? event.t, event.t) }
            case .active, .unlock, .wake:
                back(event.t)
                present(event.t)
                if current != nil { segmentStart = event.t }
            case .quit:
                if current?.name == event.appName { close(event.t); current = nil }
            case .launch, .displays:
                continue
            }
        }
        if awayStart == nil, let last = stats.lastActivity { close(last) }
        return stats
    }

    /// The longest time away of 20 minutes or more that starts between 11:00 and 14:00.
    static func lunchGap(_ stats: DayStats, calendar: Calendar) -> DateInterval? {
        stats.away.filter {
            let minute = minuteOfDay($0.start, calendar)
            return $0.duration >= 20 * 60 && minute >= 11 * 60 && minute < 14 * 60
        }.max { $0.duration < $1.duration }
    }

    /// The median first-activity minute of the given days, or nil with fewer than 3.
    static func medianStart(_ starts: [Date], calendar: Calendar) -> Int? {
        let minutes = starts.map { minuteOfDay($0, calendar) }.sorted()
        guard minutes.count >= 3 else { return nil }
        let mid = minutes.count / 2
        return minutes.count.isMultiple(of: 2) ? (minutes[mid - 1] + minutes[mid]) / 2 : minutes[mid]
    }

    // MARK: Digest

    /// The morning digest for `day`: about ten short lines, app usage and timing only. Nil for a day with no activity.
    /// `previousStarts` are the first activities of up to 28 earlier days.
    static func digest(day: Date, events: [ActivityEvent], previousStarts: [Date], excluded: [ExcludedApp],
                       calendar: Calendar) -> String? {
        let stats = stats(events, excluded: excluded)
        guard let first = stats.firstActivity, let last = stats.lastActivity else { return nil }
        var lines = ["Zeus's summary of \(dayName(day, calendar)) (app usage and timing only):"]
        lines.append("- Active \(clock(first, calendar))–\(clock(last, calendar)), about \(duration(stats.activeSeconds)) at the Mac.")
        let lunch = lunchGap(stats, calendar: calendar)
        if let lunch { lines.append("- Lunch gap \(clock(lunch.start, calendar))–\(clock(lunch.end, calendar)).") }
        let breaks = stats.away.filter { $0 != lunch && $0.duration >= 15 * 60 }
        if !breaks.isEmpty {
            let total = breaks.reduce(0) { $0 + $1.duration }
            lines.append("- \(breaks.count == 1 ? "1 other break" : "\(breaks.count) other breaks") of 15 min or more, \(duration(total)) in all.")
        }
        // A name that contains an excluded name never appears, even if that app itself isn't on the list.
        let names = stats.appSeconds.filter { name, seconds in seconds >= 60 && !mentionsExcluded(name, excluded) }
        if let firstApp = stats.firstApp, !mentionsExcluded(firstApp.name, excluded) {
            lines.append("- First app: \(firstApp.name) at \(clock(firstApp.at, calendar)).")
        }
        let top = names.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5)
        if !top.isEmpty { lines.append("- Top apps: " + top.map { "\($0.key) \(duration($0.value))" }.joined(separator: ", ") + ".") }
        if stats.privateSeconds >= 60 { lines.append("- Private time: \(duration(stats.privateSeconds)) in apps you keep private.") }
        if let median = medianStart(previousStarts, calendar: calendar) {
            let difference = minuteOfDay(first, calendar) - median
            let usual = "\(clock(minutes: median)), the median of the last 4 weeks"
            if abs(difference) < 10 { lines.append("- Started about when you usually do (\(usual)).") }
            else {
                lines.append("- Started \(duration(Double(abs(difference)) * 60)) \(difference > 0 ? "later" : "earlier") than usual (\(usual)).")
            }
        } else {
            lines.append("- Not enough days yet to compare with your usual start.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Moments

    /// Moments `event` makes, given the same day's earlier events. The caller gates them.
    static func moments(after event: ActivityEvent, earlier: [ActivityEvent], medianStart: Int?, calendar: Calendar) -> [Moment] {
        guard event.showsPresence else { return [] }
        let sameDay = earlier.filter { calendar.isDate($0.t, inSameDayAs: event.t) && $0.t <= event.t }
        if !sameDay.contains(where: \.showsPresence) {
            var found = [Moment(kind: .firstActivity, text: "First activity today at \(clock(event.t, calendar)).")]
            if let median = medianStart, minuteOfDay(event.t, calendar) - median > lateStartMargin {
                let late = Double(minuteOfDay(event.t, calendar) - median) * 60
                found.append(Moment(kind: .lateStart, text: "Later start than usual: first activity at \(clock(event.t, calendar)), "
                                    + "\(duration(late)) after the usual \(clock(minutes: median))."))
            }
            return found
        }
        // Back after a long absence: the last thing before this event was the start of one.
        guard let lastAbsence = sameDay.last(where: { $0.startsAbsence || $0.showsPresence }), lastAbsence.startsAbsence else { return [] }
        let away = event.t.timeIntervalSince(lastAbsence.t)
        guard away >= breakForMoment else { return [] }
        return [Moment(kind: .backFromBreak, text: "Back at the Mac at \(clock(event.t, calendar)) after \(duration(away)) away.")]
    }

    /// "Day winding down": no input for 20 minutes, starting after 17:00.
    static func windingDown(idleSince: Date, now: Date, calendar: Calendar) -> Moment? {
        guard minuteOfDay(idleSince, calendar) >= windingDownAfterMinute, now.timeIntervalSince(idleSince) >= windingDownIdle,
              calendar.isDate(idleSince, inSameDayAs: now) else { return nil }
        return Moment(kind: .windingDown, text: "Day winding down: no input since \(clock(idleSince, calendar)).")
    }

    /// Only ticked kinds, each once a day (breaks may repeat), and at most four a day in all.
    static func gate(_ moments: [Moment], ticked: Set<MomentKind>, sentToday: [MomentKind]) -> [Moment] {
        var sent = sentToday
        var accepted: [Moment] = []
        for moment in moments where ticked.contains(moment.kind) {
            guard sent.count < maxMomentsPerDay else { break }
            if moment.kind != .backFromBreak && sent.contains(moment.kind) { continue }
            sent.append(moment.kind)
            accepted.append(moment)
        }
        return accepted
    }

    // MARK: Words

    /// "4 h 10 min", "35 min", "under a minute".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
    static func clock(_ date: Date, _ calendar: Calendar) -> String { clock(minutes: minuteOfDay(date, calendar)) }
    static func clock(minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    static func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static func dayName(_ day: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: day)
    }

    static func isExcluded(_ event: ActivityEvent, _ excluded: [ExcludedApp]) -> Bool {
        excluded.contains { $0.matches(bundleID: event.app, name: event.name) }
    }
    private static func mentionsExcluded(_ name: String, _ excluded: [ExcludedApp]) -> Bool {
        excluded.contains { name.localizedCaseInsensitiveContains($0.name) }
    }
}
