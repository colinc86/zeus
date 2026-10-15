import Foundation

/// One already-redacted stretch, supplied by the journal adapter. The viewer never reconstructs missing words.
struct JournalTypingRun: Identifiable, Equatable {
    let item: JournalItem
    let topic: String
    let words: String?
    let missingWordsCaption: String
    var id: String { item.id }
    var time: Date { item.time }
    var app: String { item.app ?? "" }
    var segments: [TypingWordsSegment] { TypingWordsSegment.parse(words ?? "") }
}

enum TypingWordsSegment: Equatable {
    case text(String), pasted
    static func parse(_ words: String) -> [Self] {
        let parts = words.components(separatedBy: "‹pasted›")
        var result: [Self] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { result.append(.pasted) }
            if !part.isEmpty { result.append(.text(part)) }
        }
        return result
    }
}

struct JournalTypingGroup: Identifiable, Equatable {
    let app: String
    let hour: Date
    let end: Date
    let runs: [JournalTypingRun]
    var id: String { "typing:\(app):\(hour.timeIntervalSince1970)" }
    var time: Date { runs.map(\.time).max() ?? hour }
    func rangeLabel(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "HH:mm"
        return formatter.string(from: hour) + "–" + formatter.string(from: end)
    }
    static func grouped(_ runs: [JournalTypingRun], calendar: Calendar = .current) -> [Self] {
        struct Key: Hashable { let app: String; let hour: Date }
        let buckets = Dictionary(grouping: runs) { run in
            Key(app: run.app, hour: calendar.dateInterval(of: .hour, for: run.time)?.start ?? run.time)
        }
        return buckets.map { key, values in
            Self(app: key.app, hour: key.hour, end: calendar.date(byAdding: .hour, value: 1, to: key.hour) ?? key.hour,
                runs: values.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time })
        }.sorted { $0.app == $1.app ? $0.hour > $1.hour : $0.app.localizedStandardCompare($1.app) == .orderedAscending }
    }
}
