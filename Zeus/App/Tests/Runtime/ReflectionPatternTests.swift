import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@Suite struct ReflectionPatternTests {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Chicago") ?? .gmt
        return value
    }
    static func fixture(days: Int = 21) -> (Date, [JournalItem]) {
        let calendar = calendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)) ?? .distantPast
        var rows: [JournalItem] = []
        for offset in 0..<days {
            let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            func date(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day }
            for (suffix, hour, minute, app, kind) in [("mail", 9, 0, "com.apple.mail", "activate"), ("calendar", 9, 5, "com.apple.calendar", "activate"), ("editor", 9, 10, "com.apple.Xcode", "activate"), ("idle", 12, 30, "", "idle"), ("back", 13, 10, "", "active"), ("end", 18, 15, "", "lock")] {
                rows.append(.init(id: "j_\(offset)_\(suffix)", time: date(hour, minute), level: .activity, app: app.isEmpty ? nil : app, kind: .activity,
                    payload: .init(.init(description: "Synthetic \(kind)", details: ["kind": kind]))))
            }
            rows.append(.init(id: "j_\(offset)_focus", time: date(9, 15), level: .focus, app: "com.apple.Xcode", kind: .focus, payload: .init(.init(description: "Editing synthetic release notes"))))
            rows.append(.init(id: "j_\(offset)_screen", time: date(10), level: .screen, app: "com.apple.Xcode", kind: .description, payload: .init(.init(description: "Reviewing release notes ‹name›"))))
            rows.append(.init(id: "j_\(offset)_typed", time: date(11), level: .typed, app: "com.apple.Xcode", kind: .typedText,
                payload: .init(.init(description: "NEVER_TYPED_DESCRIPTION", text: "NEVER_RAW_WORDS", topic: offset >= 14 ? "Planning next release" : "Drafting release notes"))))
        }
        return ((calendar.date(byAdding: .day, value: days - 1, to: start) ?? start), rows)
    }
    @Test func threeWeeksProduceCrossDayPatternsWithStableLocalEvidence() throws {
        let (day, rows) = Self.fixture()
        let local = ReflectionLocalTime(calendar: Self.calendar)
        let feedback = [0, 7, 14].map { offset in
            ReflectionPatternDigest.Feedback(reference: .init(id: "c_\(offset)", at: rows[offset * 9].time, journal: false), label: "Meeting prep", state: "answered")
        }
        let builder = ReflectionPatternDigest(time: local, day: day, levels: Set(JournalLevel.allCases), items: rows, feedback: feedback)
        let digest = builder.build()
        for heading in ["Rhythm", "Focus", "Sequences", "Topics", "Engagement", "Today vs usual"] { #expect(digest.text.contains(heading)) }
        #expect(digest.text.contains("Mail then Calendar about 09:00, every day seen"))
        #expect(!digest.text.contains("09:00–09:00") && !digest.text.contains("com.apple."))
        #expect(digest.text.contains("New in this week's observations"))
        #expect(digest.text.contains("09:00")); #expect(digest.text.contains("‹name›"))
        #expect(!digest.text.contains("NEVER_")); #expect(!digest.text.contains("app="))
        #expect(digest.text == ReflectionPatternDigest(time: local, day: day, levels: Set(JournalLevel.allCases), items: rows.reversed(), feedback: feedback.reversed()).build().text)
        let appendix = digest.text.components(separatedBy: "Today, last records (at most 20)")[0]
        for line in appendix.split(separator: "\n") where line.hasPrefix("- ") {
            let citation = try #require(line.split(separator: "[").last)
            let ids = citation.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
            #expect((2...4).contains(ids.count))
            let dates = digest.references.filter { ids.contains($0.id) }.map { local.dayKey($0.at) }
            #expect(Set(dates).count == ids.count)
        }
    }
    @Test func boundLevelsAndNoInventedDurationForUnobservedTail() throws {
        let (day, rows) = Self.fixture(days: 35)
        let local = ReflectionLocalTime(calendar: Self.calendar)
        let digest = ReflectionPatternDigest(time: local, day: day, levels: [.typed], items: rows, feedback: []).build(byteLimit: 1500)
        #expect(digest.text.utf8.count <= 1500)
        #expect(!digest.text.contains("NEVER_")); #expect(!digest.text.contains("Synthetic activate"))
        let start = try #require(Self.calendar.date(byAdding: .day, value: -27, to: day))
        #expect(digest.references.allSatisfy { $0.id.hasSuffix("_typed") && $0.at >= start })
        let first = rows[0]
        let singleton = ReflectionPatternDigest(time: local, day: first.time, levels: [.activity], items: [first], feedback: []).build()
        #expect(!singleton.text.contains("Focus\n")); #expect(!singleton.text.contains("Rhythm\n"))
        let off = ReflectionPatternDigest(time: local, day: day, levels: [], items: rows, feedback: []).build()
        #expect(off.text.isEmpty && off.references.isEmpty)
    }
    @Test func weekdaysOnlyBreakOutWhenTheyDifferAndCopyUsesOneVocabulary() {
        let (day, rows) = Self.fixture()
        let shifted = rows.map { row in
            JournalItem(id: row.id, time: row.time.addingTimeInterval(Self.calendar.component(.weekday, from: row.time) == 2 ? 3600 : 0),
                        level: row.level, app: row.app, kind: row.kind, payload: row.payload)
        }
        let result = ReflectionPatternDigest(time: .init(calendar: Self.calendar), day: day, levels: Set(JournalLevel.allCases), items: shifted, feedback: []).build()
        #expect(result.text.contains("Mondays (3 seen): first activity about 10:00, first window Xcode about 10:15"))
        #expect(!result.text.contains("Tuesdays (3 seen)"))
        #expect(!result.text.contains("first observation") && !result.text.contains("first focus sample"))
        #expect(result.text.contains("Today's first activity was about when it usually is (09:00)."))
        #expect(result.text.components(separatedBy: "Durations are estimates").count == 2)
    }
    @Test func privateIntervalsDoNotBecomeAppTimeOrSequencesAndAppendixIsBounded() {
        let (day, original) = Self.fixture()
        var rows = original.filter { $0.level == .activity }
        for row in original where row.id.hasSuffix("_mail") {
            rows.append(.init(id: row.id + "_private", time: row.time.addingTimeInterval(60), level: .activity, kind: .activity,
                payload: .init(.init(description: "Private interval", details: ["kind": "private"]))))
        }
        for index in 0..<40 {
            rows.append(.init(id: "extra_\(index)", time: day.addingTimeInterval(Double(index)), level: .activity, kind: .activity,
                payload: .init(.init(description: "Extra observation", details: ["kind": "activate"]))))
        }
        let result = ReflectionPatternDigest(time: .init(calendar: Self.calendar), day: day, levels: [.activity], items: rows, feedback: []).build(byteLimit: 10_000)
        #expect(!result.text.contains("Mail then"))
        #expect(!result.text.contains(": Mail, about"))
        let appendix = result.text.components(separatedBy: "Today, last records (at most 20)\n").last ?? ""
        #expect(appendix.split(separator: "\n").count <= 20)
    }
    @Test func localKeysCrossUTCMidnightAndDST() throws {
        let local = ReflectionLocalTime(calendar: Self.calendar)
        let formatter = ISO8601DateFormatter()
        let a = try #require(formatter.date(from: "2026-10-14T23:50:00Z")), b = try #require(formatter.date(from: "2026-10-15T00:10:00Z"))
        #expect(local.dayKey(a) == "2026-10-14" && local.dayKey(b) == "2026-10-14")
        let c = try #require(formatter.date(from: "2026-10-15T05:10:00Z"))
        #expect(local.dayKey(c) == "2026-10-15")
        let before = try #require(formatter.date(from: "2026-11-01T06:30:00Z")), after = try #require(formatter.date(from: "2026-11-01T07:30:00Z"))
        #expect(local.label(before, "HH:mm") == local.label(after, "HH:mm"))
        #expect(local.dayKey(before) == local.dayKey(after))
    }
}

@Suite @MainActor struct ReflectionPatternRuntimeTests {
    @Test func validatorNamesLocalDaysAndAcceptsCrossDayEvidence() async throws {
        let f = try LearningRuntimeFixture(calendar: ReflectionPatternTests.calendar); defer { f.stop() }
        f.box.enabled = true
        let formatter = ISO8601DateFormatter()
        for (id, stamp) in [("a", "2026-10-14T23:50:00Z"), ("b", "2026-10-15T00:10:00Z"), ("c", "2026-10-15T05:10:00Z")] {
            try f.journal.append(.init(id: id, time: try #require(formatter.date(from: stamp)), level: .focus, kind: .focus, payload: .init(.init(description: "Synthetic work"))))
        }
        var delivery = Delivery(id: "reflection-fixture", kind: .reflection, sessionKey: "claude:/fixture#123.1", content: "Fixture", createdAt: f.clock.now)
        delivery.meta["evidence"] = "a,b,c"; try f.runtime.ledger?.insert(.init(delivery: delivery))
        func args(_ ids: [String]) -> JSONValue { ["rules": [["sentence": "Keep project updates quiet", "trigger": ["state": "tests running"], "evidence": .array(ids.map(JSONValue.string))]]] }
        let bad = await f.runtime.callTool("zeus_propose_rules", arguments: args(["a", "b"]), sessionKey: delivery.sessionKey)
        #expect(bad.isError); #expect(bad.text.contains("2026-10-14")); #expect(bad.text.contains("a (") && bad.text.contains("b ("))
        let good = await f.runtime.callTool("zeus_propose_rules", arguments: args(["a", "c"]), sessionKey: delivery.sessionKey)
        #expect(!good.isError)
    }
    @Test func deletingUncitedAggregateSourceDiscardsReflectionAndLateReceipt() async throws {
        let f = try LearningRuntimeFixture(calendar: ReflectionPatternTests.calendar); defer { f.stop() }
        let (day, rows) = ReflectionPatternTests.fixture()
        f.clock.now = day.addingTimeInterval(20 * 3600); f.connector.available = false
        for row in rows { try f.journal.append(row) }
        f.box.enabled = true; f.box.context.idleSince = f.clock.now.addingTimeInterval(-601)
        f.runtime.learningContextDidChange()
        try await eventually { f.runtime.ledger?.records.contains { $0.delivery.kind == .reflection } == true }
        let sent = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .reflection }?.delivery)
        let cited = Set(sent.meta["evidence", default: ""].split(separator: ",").map(String.init))
        let uncited = try #require(rows.first { !cited.contains($0.id) })
        #expect(sent.meta["source_hash"] != nil)
        try f.journal.delete(.item(uncited.id)); f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.record(id: sent.id)?.discardedAt != nil)
        f.runtime.recordReflectionReceipt(id: sent.id)
        #expect(try f.journal.items(matching: .init()).allSatisfy { $0.kind != .sentToAssistant })
    }
    @Test func feedbackEvidenceMustBeListedAndStillRetained() async throws {
        let f = try LearningRuntimeFixture(messageRatings: true); defer { f.stop() }
        f.box.enabled = true
        let store = try #require(f.ratingStore)
        for (id, offset) in [("c_first", -86400.0), ("c_second", 0.0)] {
            var card = Card(id: id, kind: .message, body: "Synthetic reminder", createdAt: f.clock.now.addingTimeInterval(offset))
            card.about = "Meeting prep"; card.origin = .unprompted
            f.cards.add(card); store.observeCard(card); store.signal(id: id, edge: "opened", at: f.clock.now)
        }
        let dates = f.runtime.reflectionFeedbackDates().mapValues { $0.timeIntervalSince1970 }
        var delivery = Delivery(id: "feedback-reflection", kind: .reflection, sessionKey: "claude:/fixture#123.1", content: "Fixture", createdAt: f.clock.now)
        delivery.meta["feedback_evidence"] = String(decoding: try JSONEncoder().encode(dates), as: UTF8.self)
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        let args: JSONValue = ["rules": [["sentence": "Keep meeting prep quiet during tests", "trigger": ["state": "tests running"], "evidence": ["c_first", "c_second"]]]]
        let accepted = await f.runtime.callTool("zeus_propose_rules", arguments: args, sessionKey: delivery.sessionKey)
        #expect(!accepted.isError)
        f.cards.values.removeAll { $0.id == "c_first" }
        let removed = await f.runtime.callTool("zeus_propose_rules", arguments: args, sessionKey: delivery.sessionKey)
        #expect(removed.isError && removed.text.contains("c_first"))
        #expect(f.runtime.reflectionFeedbackDates()["c_first"] == nil)
    }
    @Test func enabledLevelsBoundWholeDeliveryAndRevocationCancelsPending() async throws {
        let f = try LearningRuntimeFixture(calendar: ReflectionPatternTests.calendar); defer { f.stop() }
        f.connector.available = false
        let (day, rows) = ReflectionPatternTests.fixture()
        f.clock.now = day.addingTimeInterval(20 * 3600)
        for row in rows { try f.journal.append(row) }
        f.runtime.journalAccessPolicy = { .init(enabledLevels: [.typed]) }
        f.box.context.idleSince = f.clock.now.addingTimeInterval(-601); f.box.enabled = true; f.runtime.learningContextDidChange()
        try await eventually { f.runtime.ledger?.records.contains { $0.delivery.kind == .reflection } == true }
        let delivery = try #require(f.runtime.ledger?.records.first { $0.delivery.kind == .reflection }?.delivery)
        #expect(delivery.content.utf8.count <= 10_240)
        #expect(!delivery.content.contains("NEVER_") && !delivery.content.contains("Synthetic activate"))
        #expect(delivery.content.contains("Notes/patterns.md"))
        f.runtime.journalAccessPolicy = { .init() }; f.runtime.learningContextDidChange()
        #expect(f.runtime.ledger?.record(id: delivery.id)?.discardedAt != nil)
    }
}
