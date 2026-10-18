import Foundation
import CryptoKit

/// Stable local-day identities shared by the digest and proposal validation.
struct ReflectionLocalTime {
    let calendar: Calendar
    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func label(_ date: Date, _ format: String = "EEE d MMM") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = format
        return formatter.string(from: date)
    }
    func minute(_ date: Date) -> Int { calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

/// Deterministic summaries of retained observations, not a claim of complete screen or work-time coverage.
struct ReflectionPatternDigest {
    struct Reference: Equatable {
        let id: String
        let at: Date
        var journal = true
    }
    struct Feedback {
        let reference: Reference
        let label: String
        let state: String
    }
    struct Line {
        let text: String
        let references: [Reference]
    }
    struct Result {
        let text: String
        let references: [Reference]
        let sourceIDs: [String]
    }
    let time: ReflectionLocalTime
    let day: Date
    let levels: Set<JournalLevel>
    let items: [JournalItem]
    let feedback: [Feedback]

    static func clean(_ value: String, limit: Int = 160) -> String {
        String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }
    private func ref(_ item: JournalItem) -> Reference { .init(id: item.id, at: item.time) }
    private func distinctDays(_ refs: [Reference]) -> [Reference] {
        var seen: Set<String> = []
        let sorted = refs.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        let unique = sorted.filter { seen.insert(time.dayKey($0.at)).inserted }
        guard unique.count > 4 else { return unique }
        return (0..<4).map { unique[$0 * (unique.count - 1) / 3] }
    }
    private func line(_ text: String, _ refs: [Reference]) -> Line? {
        let refs = distinctDays(refs)
        return refs.count >= 2 ? .init(text: text, references: refs) : nil
    }
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
    private func clocks(_ values: [Int]) -> String {
        let middle = ReflectionLocalTime.clock(Int(median(values.map(Double.init))))
        guard let low = values.min(), let high = values.max(), high - low >= 10 else { return "about " + middle }
        return "about \(middle) (\(ReflectionLocalTime.clock(low))–\(ReflectionLocalTime.clock(high)))"
    }
    private func firstPresence(_ rows: [JournalItem]) -> JournalItem? {
        rows.first { !["sleep", "wake", "lock", "idle", "quit", "launch", "displays", "private"].contains($0.payload.value.details["kind"] ?? "") }
    }
    private func app(_ item: JournalItem) -> String {
        if let name = item.payload.value.details["name"] ?? item.payload.value.details["appName"], !name.isEmpty { return Self.clean(name, limit: 60) }
        guard let identifier = item.app, let last = identifier.split(separator: ".").last else { return "Unknown app" }
        return Self.clean(last.prefix(1).uppercased() + last.dropFirst(), limit: 60)
    }
    private func commonApp(_ rows: [JournalItem]) -> String {
        let counts = Dictionary(grouping: rows, by: app).mapValues(\.count)
        return counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0, default: 0] > counts[$1, default: 0] }.first ?? "Unknown app"
    }
    private func category(_ item: JournalItem) -> String {
        let name = (item.app ?? app(item)).lowercased()
        if ["xcode", "vscode", "jetbrains", "terminal", "warp"].contains(where: name.contains) { return "development" }
        if ["mail", "slack", "teams", "messages"].contains(where: name.contains) { return "communication" }
        if name.contains("calendar") { return "planning" }
        if ["logic", "photoshop", "figma", "affinity"].contains(where: name.contains) { return "creative tools" }
        if ["safari", "chrome", "firefox"].contains(where: name.contains) { return "browsing" }
        if ["pages", "word", "notes", "obsidian"].contains(where: name.contains) { return "writing" }
        return "other apps"
    }
    private func part(_ date: Date) -> String {
        switch time.calendar.component(.hour, from: date) {
        case 0..<6: "Overnight"
        case 6..<12: "Mornings"
        case 12..<18: "Afternoons"
        default: "Evenings"
        }
    }

    static func eligible(_ item: JournalItem, levels: Set<JournalLevel>, from: Date, to: Date) -> Bool {
        levels.contains(item.level) && item.time >= from && item.time < to
            && [.activity, .focus, .description, .typedText].contains(item.kind)
            && (item.level != .typed || item.payload.value.topic?.isEmpty == false)
    }
    static func sourceHash(_ ids: [String]) -> String {
        let data = (try? JSONEncoder().encode(ids.sorted())) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func build(byteLimit: Int = 7_200) -> Result {
        let start = time.calendar.date(byAdding: .day, value: -27, to: time.calendar.startOfDay(for: day)) ?? day
        let end = time.calendar.date(byAdding: .day, value: 1, to: time.calendar.startOfDay(for: day)) ?? day
        let records = items.filter { Self.eligible($0, levels: levels, from: start, to: end) }
            .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
        let days = Dictionary(grouping: records) { time.dayKey($0.time) }
        let orderedDays = days.keys.sorted().compactMap { days[$0] }
        let weekdayNames = Dictionary(uniqueKeysWithValues: orderedDays.map { (time.dayKey($0[0].time), time.label($0[0].time, "EEEE")) })
        var sections: [(String, [Line])] = []
        var rhythm: [Line] = []
        let firstObservations = orderedDays.compactMap(firstPresence)
        let lastObservations = orderedDays.compactMap(\.last)
        let firstFocus = orderedDays.compactMap { $0.first { $0.kind == .focus } }
        if let row = line("First activity \(clocks(firstObservations.map { time.minute($0.time) })); last activity \(clocks(lastObservations.map { time.minute($0.time) })) (\(orderedDays.count) days seen).", firstObservations.map(ref)) { rhythm.append(row) }
        if let row = line("First window: \(commonApp(firstFocus)) \(clocks(firstFocus.map { time.minute($0.time) })) (\(firstFocus.count) days seen).", firstFocus.map(ref)) { rhythm.append(row) }
        func middle(_ rows: [JournalItem]) -> Double { median(rows.map { Double(time.minute($0.time)) }) }
        for weekday in 1...7 {
            let groups = orderedDays.filter { time.calendar.component(.weekday, from: $0[0].time) == weekday }
            guard groups.count >= 2 else { continue }
            let first = groups.compactMap(firstPresence), last = groups.compactMap(\.last)
            let focus = groups.compactMap { $0.first { $0.kind == .focus } }
            guard abs(middle(first) - middle(firstObservations)) >= 15 || abs(middle(last) - middle(lastObservations)) >= 15
                || (!focus.isEmpty && (abs(middle(focus) - middle(firstFocus)) >= 15 || commonApp(focus) != commonApp(firstFocus))) else { continue }
            let name = time.label(groups[0][0].time, "EEEE")
            let window = focus.isEmpty ? "" : ", first window \(commonApp(focus)) \(clocks(focus.map { time.minute($0.time) }))"
            if let row = line("\(name)s (\(groups.count) seen): first activity \(clocks(first.map { time.minute($0.time) }))\(window), last activity \(clocks(last.map { time.minute($0.time) })).", first.map(ref)) { rhythm.append(row) }
        }
        var breaks: [(Double, Reference)] = []
        for rows in orderedDays {
            var away: JournalItem?
            for row in rows where row.level == .activity {
                let kind = row.payload.value.details["kind"]
                if ["idle", "lock", "sleep"].contains(kind ?? "") { if away == nil { away = row } }
                else if ["active", "unlock", "activate"].contains(kind ?? ""), let beginning = away {
                    let minutes = row.time.timeIntervalSince(beginning.time) / 60
                    if minutes >= 5 && minutes <= 240 { breaks.append((minutes, ref(beginning))) }
                    away = nil
                }
            }
        }
        if let row = line("Recorded breaks last about \(Int(median(breaks.map(\.0)))) min (\(Int(breaks.map(\.0).min() ?? 0))–\(Int(breaks.map(\.0).max() ?? 0)) min); only closed away/return intervals are counted.", breaks.map(\.1)) { rhythm.insert(row, at: 0) }
        sections.append(("Rhythm", rhythm))

        struct Span { let item: JournalItem; let minutes: Double }
        var spans: [Span] = []
        for rows in orderedDays {
            let activity = rows.filter { $0.level == .activity }
            let stream = activity.contains { $0.payload.value.details["kind"] == "activate" } ? activity : rows.filter { $0.kind == .focus }
            for pair in zip(stream, stream.dropFirst()) {
                let (a, b) = pair
                guard a.app != nil, a.kind == .focus || a.payload.value.details["kind"] == "activate",
                      b.payload.value.details["kind"] != "private" else { continue }
                let minutes = min(15, max(0, b.time.timeIntervalSince(a.time) / 60))
                if minutes > 0 { spans.append(.init(item: a, minutes: minutes)) }
            }
        }
        var focus: [Line] = []
        let focusGroups = Dictionary(grouping: spans) { part($0.item.time) + ": " + app($0.item) }
        let focusKeys = focusGroups.keys.sorted {
            let a = focusGroups[$0, default: []].reduce(0) { $0 + $1.minutes }, b = focusGroups[$1, default: []].reduce(0) { $0 + $1.minutes }
            return a == b ? $0 < $1 : a > b
        }
        for key in focusKeys.prefix(12) {
            let values = focusGroups[key, default: []]
            let byDay = Dictionary(grouping: values) { time.dayKey($0.item.time) }
            let daily = byDay.values.map { $0.reduce(0) { $0 + $1.minutes } }
            let weekdays = Set(values.compactMap { weekdayNames[time.dayKey($0.item.time)] }).sorted()
            let coverage = byDay.count == orderedDays.count ? "every day seen" : (weekdays.count == 1 ? "\(weekdays[0])s, \(byDay.count) days seen" : "\(byDay.count) days seen")
            if let row = line("\(key), about \(Int(median(daily).rounded())) min (\(coverage)).", values.map { ref($0.item) }) { focus.append(row) }
            let byWeekday = Dictionary(grouping: values) { weekdayNames[time.dayKey($0.item.time)] ?? "" }
            for weekday in byWeekday.keys.sorted() {
                let subset = byWeekday[weekday, default: []]
                let minutes = Dictionary(grouping: subset) { time.dayKey($0.item.time) }.values.map { $0.reduce(0) { $0 + $1.minutes } }
                guard abs(median(minutes) - median(daily)) >= 15 else { continue }
                if let row = line("\(weekday)s, \(key): about \(Int(median(minutes).rounded())) min (\(minutes.count) days seen).", subset.map { ref($0.item) }) { focus.append(row) }
            }
        }
        let categories = Dictionary(grouping: spans) { part($0.item.time) + ": " + category($0.item) }
        for key in categories.keys.sorted() {
            let values = categories[key, default: []]
            guard Set(values.map { app($0.item) }).count > 1 else { continue }
            let daily = Dictionary(grouping: values) { time.dayKey($0.item.time) }.values.map { $0.reduce(0) { $0 + $1.minutes } }
            if let row = line("\(key), about \(Int(median(daily).rounded())) min across those apps (\(daily.count) days seen).", values.map { ref($0.item) }) { focus.append(row) }
        }
        sections.append(("Focus", focus))

        var sequences: [String: [JournalItem]] = [:]
        for rows in orderedDays {
            let switches = rows.filter { $0.level == .activity }
            for (a, b) in zip(switches, switches.dropFirst()) where a.payload.value.details["kind"] == "activate" && b.payload.value.details["kind"] == "activate" && a.app != b.app && b.time.timeIntervalSince(a.time) <= 900 {
                let key = "\(app(a)) then \(app(b))"
                sequences[key, default: []].append(a)
            }
        }
        let sequenceLines = sequences.keys.sorted().compactMap { key -> Line? in
            let values = sequences[key, default: []]
            guard !values.isEmpty else { return nil }
            let count = Set(values.map { time.dayKey($0.time) }).count
            let weekdays = Set(values.compactMap { weekdayNames[time.dayKey($0.time)] }).sorted()
            let coverage = count == orderedDays.count ? "every day seen" : (weekdays.count == 1 ? "on \(weekdays[0])s (\(count) days seen)" : "\(count) of \(orderedDays.count) days seen")
            return line("\(key) \(clocks(values.map { time.minute($0.time) })), \(coverage).", values.map(ref))
        }
        sections.append(("Sequences", sequenceLines))

        let topicRows = records.filter { $0.kind == .description || $0.kind == .typedText }
        let topics = Dictionary(grouping: topicRows) { Self.clean($0.level == .typed ? ($0.payload.value.topic ?? "") : $0.payload.value.description).lowercased() }
        let week = time.calendar.date(byAdding: .day, value: -6, to: time.calendar.startOfDay(for: day)) ?? day
        let topicLines = topics.keys.sorted().compactMap { key -> Line? in
            let values = topics[key, default: []]
            guard !key.isEmpty else { return nil }
            let fresh = values.allSatisfy { $0.time >= week }
            return line("\(fresh ? "New in this week's observations" : "Recurring topic"): \(key), on \(Set(values.map { time.dayKey($0.time) }).count) local days.", values.map(ref))
        }
        sections.append(("Topics", topicLines))
        let feedbackGroups = Dictionary(grouping: feedback.filter { $0.reference.at >= start && $0.reference.at < end }) { Self.clean($0.label, limit: 70) }
        let engagement = feedbackGroups.keys.sorted().compactMap { label -> Line? in
            let values = feedbackGroups[label, default: []]
            let counts = Dictionary(grouping: values, by: \.state).mapValues(\.count)
            let words = counts.keys.sorted().map { "\(counts[$0, default: 0]) \($0)" }.joined(separator: ", ")
            return line("\(label): \(words).", values.map(\.reference))
        }
        sections.append(("Engagement", engagement))
        let todays = days[time.dayKey(day)] ?? []
        let starts = orderedDays.filter { time.dayKey($0[0].time) != time.dayKey(day) }.compactMap(firstPresence)
        var differences: [Line] = []
        if let first = firstPresence(todays), starts.count >= 2 {
            let usual = Int(median(starts.map { Double(time.minute($0.time)) }))
            let delta = time.minute(first.time) - usual
            let text = abs(delta) < 10
                ? "Today's first activity was about when it usually is (\(ReflectionLocalTime.clock(usual)))."
                : "Today started \(abs(delta)) min \(delta > 0 ? "later" : "earlier") than usual (\(ReflectionLocalTime.clock(time.minute(first.time))) against about \(ReflectionLocalTime.clock(usual)))."
            if let row = line(text, [ref(first)] + starts.suffix(3).map(ref)) { differences.append(row) }
        }
        sections.append(("Today vs usual", differences))
        let appendix = todays.suffix(20).map { row in
            Line(text: "\(time.label(row.time, "HH:mm")) \(app(row)) · \(Self.clean(row.level == .typed ? (row.payload.value.topic ?? "") : row.payload.value.description))", references: [ref(row)])
        }
        sections.append(("Today, last records (at most 20)", appendix))

        let introductions = ["Rhythm": "Last activity is a wind-down clue, not proof you stopped.",
                             "Focus": "Durations are estimates from adjacent events, capped at 15 min between them.",
                             "Sequences": "Switches within 15 minutes of each other."]
        func heading(_ index: Int) -> String {
            sections[index].0 + (introductions[sections[index].0].map { "\n" + $0 } ?? "")
        }
        // Share space across sections before filling any one section, so noisy apps cannot crowd out topics.
        var chosen: [[Line]] = Array(repeating: [], count: sections.count)
        var used = 0
        for index in 0..<(sections.map { $0.1.count }.max() ?? 0) {
            for section in sections.indices where sections[section].1.indices.contains(index) {
                let row = sections[section].1[index]
                let rendered = render(row)
                let cost = rendered.utf8.count + 1 + (chosen[section].isEmpty ? heading(section).utf8.count + 2 : 0)
                guard used + cost <= byteLimit else { continue }
                chosen[section].append(row); used += cost
            }
        }
        let text = sections.indices.filter { !chosen[$0].isEmpty }.map { heading($0) + "\n" + chosen[$0].map(render).joined(separator: "\n") }.joined(separator: "\n\n")
        var seen: Set<String> = []
        let refs = chosen.flatMap { $0 }.flatMap(\.references).filter { seen.insert($0.id).inserted }
        return .init(text: text, references: refs, sourceIDs: records.map(\.id))
    }
    private func render(_ line: Line) -> String {
        "- " + line.text + " [" + line.references.map { "\($0.id) \(time.label($0.at))" }.joined(separator: ", ") + "]"
    }
}
