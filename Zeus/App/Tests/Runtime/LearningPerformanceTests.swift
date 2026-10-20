import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// A synthetic retained journal of realistic size, written straight into the encrypted day partitions of an
/// isolated store (scratch folder, fixture key; never the keychain or the user's home).
@MainActor enum LearningBenchmarkJournal {
    static func seed(_ f: LearningRuntimeFixture, days: Int, perDay: Int) throws -> [JournalItem] {
        let root = f.journal.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: f.clock.now)
        let apps = ["com.apple.dt.Xcode", "com.apple.Safari", "com.apple.Terminal", "com.apple.mail", "com.apple.Notes"]
        var sample: [JournalItem] = []
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let span = back == 0 ? max(60, f.clock.now.timeIntervalSince(today) - 120) : 86_000
            var rows: [JournalItem] = []
            for i in 0..<perDay {
                let time = day.addingTimeInterval(span * Double(i) / Double(perDay))
                let app = apps[i % apps.count]
                let id = "bench-\(back)-\(i)"
                let item: JournalItem
                switch i % 10 {
                case 0..<5:
                    item = .init(id: id, time: time, level: .activity, app: app, kind: .activity,
                        payload: .init(.init(description: "Switched to \(app.split(separator: ".").last ?? "")", details: ["duration": String(i % 300), "bundle": app])))
                case 5..<9:
                    item = .init(id: id, time: time, level: .focus, app: app, kind: .focus,
                        payload: .init(.init(description: "Editing LearningFolderWriter.swift — Zeus (‹name› review \(i))", topic: "Swift performance work",
                            details: ["window": "LearningFolderWriter.swift", "url": "https://example.com/zeus/pull/\(i)"])))
                default:
                    item = .init(id: id, time: time, level: .activity, kind: .sentToAssistant,
                        payload: .init(.init(description: "Sent a learning to Claude", text: "Synthetic ledger text \(i)", details: ["delivery_id": "d_bench\(back)_\(i)"])))
                }
                rows.append(item)
            }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let url = root.appendingPathComponent(String(format: "%04d-%02d-%02d.zjournal", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            try LearningEncryption.write(rows, to: url, key: FixtureJournalKey())
            sample.append(contentsOf: rows.prefix(3)); if rows.count > 5 { sample.append(rows[5]) }
        }
        return sample
    }
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
}

@MainActor private final class CountingJournalKey: FixtureLearningKeyProviding {
    var calls = 0
    var unavailable = false
    func key() throws -> Data {
        calls += 1
        if unavailable { throw LearningStorageError.keyUnavailable }
        return Data(repeating: 42, count: 32)
    }
}

@Suite(.serialized) @MainActor struct LearningPerformanceTests {
    /// Per-event work must follow what changed, not the retained history (PERF: 50–90 % CPU spikes with Learn From Me on).
    @Test func appendRewritesOnlyItsDayAndDecodesNothing() async throws {
        let f = try LearningRuntimeFixture(exportFolder: true); defer { f.stop() }
        let folder = try #require(f.folder)
        folder.journalDebounce = .milliseconds(20)
        let sample = try LearningBenchmarkJournal.seed(f, days: 10, perDay: 60)
        await folder.flush()
        let old = try #require(sample.first { $0.level == .focus })
        let oldFile = try #require(folder.fileURL(forJournalItem: old))
        let oldBytes = try Data(contentsOf: oldFile)
        let rendered = folder.renderedDayCount, decoded = f.journal.partitionDecodeCount
        for i in 0..<3 {
            try f.journal.append(.init(id: "live-\(i)", time: f.clock.now, level: .focus, app: "com.apple.Safari", kind: .focus,
                payload: .init(.init(description: "LIVE_EVENT_\(i)"))))
            f.runtime.learningContextDidChange()
        }
        await folder.settle()
        #expect((1...2).contains(folder.renderedDayCount - rendered))
        #expect(f.journal.partitionDecodeCount == decoded)
        let today = try #require(folder.fileURL(forJournalItem: .init(id: "live-0", time: f.clock.now, level: .focus, kind: .focus, payload: .init(.init(description: "")))))
        let text = try String(contentsOf: today, encoding: .utf8)
        #expect(text.contains("LIVE_EVENT_0") && text.contains("LIVE_EVENT_2"))
        #expect(try Data(contentsOf: oldFile) == oldBytes)
        // A level change re-renders every day; a deletion re-renders the affected day and removes its file content.
        folder.enabledLevels = { [.activity] }; await folder.flush()
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        folder.enabledLevels = { [.activity, .focus] }; await folder.flush()
        #expect(try String(contentsOf: oldFile, encoding: .utf8).contains(old.payload.value.description))
        try f.journal.delete(.item(old.id)); await folder.settle()
        #expect(!((try? String(contentsOf: oldFile, encoding: .utf8))?.contains(old.payload.value.description + "\n") ?? false))
        #expect(try f.journal.items(matching: .init()).contains { $0.id == old.id } == false)
    }
    @Test func journalReadsAskForTheKeyOncePerOperationAndStillFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf_key_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = CountingJournalKey()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = EncryptedJournalStore(root: root, keyProvider: key, calendar: calendar, clock: { now })
        for day in 0..<8 {
            try store.append(.init(id: "d\(day)", time: now.addingTimeInterval(Double(-day) * 86400), level: .focus, kind: .focus, payload: .init(.init(description: "Day \(day)"))))
        }
        key.calls = 0
        try store.append(.init(id: "new", time: now, level: .focus, kind: .focus, payload: .init(.init(description: "New"))))
        #expect(key.calls == 2) // one for all reads across eight partitions, one for the write
        key.calls = 0
        #expect(try store.items(matching: .init()).count == 9)
        #expect(key.calls == 1)
        // A warm cache never bypasses an unavailable key.
        key.unavailable = true
        #expect(throws: LearningStorageError.self) { try store.items(matching: .init()) }
        key.unavailable = false
        // A partition replaced behind the store's back is re-read, not served from memory.
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "zjournal" })
        try Data("not a journal".utf8).write(to: file)
        #expect(throws: LearningStorageError.self) { try store.items(matching: .init()) }
    }
    static func presentation(_ f: LearningRuntimeFixture) throws -> (LearningPresentation, () -> Void) {
        let name = TestDefaults.suite("zeus-learning-perf"), defaults = try #require(UserDefaults(suiteName: name))
        let presentation = LearningPresentation(defaults: defaults, learn: LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil))
        presentation.install(journal: f.journal, rules: f.rules, redactor: FixtureLearningRedactor(), source: LM2FocusSource())
        return (presentation, { presentation.stop(); defaults.removePersistentDomain(forName: name) })
    }
    @Test func receivedDeliveryIDsFollowAppendsAndDeletions() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let (presentation, done) = try Self.presentation(f); defer { done() }
        func sent(_ id: String) -> JournalItem {
            .init(id: "sent-" + id, time: f.clock.now, level: .activity, kind: .sentToAssistant, payload: .init(.init(description: "Sent", details: ["delivery_id": id])))
        }
        try f.journal.append(sent("d_one"))
        #expect(presentation.receivedLearningDeliveryIDs == ["d_one"])
        try f.journal.append(sent("d_two"))
        try f.journal.append(.init(id: "other", time: f.clock.now, level: .focus, kind: .focus, payload: .init(.init(description: "Not sent", details: ["delivery_id": "d_no"]))))
        #expect(presentation.receivedLearningDeliveryIDs == ["d_one", "d_two"])
        try f.journal.delete(.all)
        #expect(presentation.receivedLearningDeliveryIDs == [])
    }
    @Test func interruptedWriteTemporaryRecordIsMergedAndErased() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("perf_sidecar_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("folder"), state = base.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Zeus"), withIntermediateDirectories: true)
        let disk = try LearningFolderDisk(stateURL: state)
        try disk.apply([.init(path: "Zeus/a.md", data: Data("A".utf8), ids: ["a"])], root: root, token: disk.invalidate())
        #expect(!FileManager.default.fileExists(atPath: state.path + ".pending"))
        // As if Zeus quit after recording a temporary path and creating the file, before the manifest write.
        let orphan = root.appendingPathComponent("Zeus/.zeus-write-orphan")
        try Data("partial".utf8).write(to: orphan)
        try JSONEncoder().encode([root.standardizedFileURL.path: Set(["Zeus/.zeus-write-orphan"])]).write(to: URL(fileURLWithPath: state.path + ".pending"))
        let reopened = try LearningFolderDisk(stateURL: state)
        #expect(!FileManager.default.fileExists(atPath: state.path + ".pending"))
        try reopened.erase(root: root, ids: nil)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Zeus/a.md").path))
    }
    @Test func appendHistoryCoversOnlyAppends() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf_history_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        let start = store.revision
        let first = JournalItem(id: "a", time: Date(), level: .focus, kind: .focus, payload: .init(.init(description: "A")))
        try store.append(first)
        #expect(store.appendedItems(since: start)?.map(\.id) == ["a"])
        #expect(store.appendedItems(since: store.revision) == [])
        try store.delete(.item("a"))
        #expect(store.appendedItems(since: start) == nil)
        let mark = store.revision
        try store.append(.init(id: "b", time: Date(), level: .focus, kind: .focus, payload: .init(.init(description: "B"))))
        #expect(store.appendedItems(since: mark)?.map(\.id) == ["b"])
    }

    /// Benchmark: per-activity-event cost (append → context change → received-IDs read → folder settled).
    /// Opt-in: `TEST_RUNNER_ZEUS_LEARNING_BENCH=1` (days × items via `..._BENCH_DAYS`, `..._BENCH_ITEMS`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_LEARNING_BENCH"] == "1"), .timeLimit(.minutes(10)))
    func appendBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        let days = Int(env["ZEUS_LEARNING_BENCH_DAYS"] ?? "") ?? 28, perDay = Int(env["ZEUS_LEARNING_BENCH_ITEMS"] ?? "") ?? 3000
        let f = try LearningRuntimeFixture(exportFolder: true); defer { f.stop() }
        let folder = try #require(f.folder)
        let sample = try LearningBenchmarkJournal.seed(f, days: days, perDay: perDay)
        var reflection = Delivery(id: "bench_reflection", kind: .reflection, sessionKey: "claude:/fixture#123.1", content: "Fixture reflection", createdAt: f.clock.now)
        reflection.meta["evidence"] = sample.prefix(4).map(\.id).joined(separator: ",")
        try f.runtime.ledger?.insert(.init(delivery: reflection))
        let (presentation, done) = try Self.presentation(f)
        defer { done() }
        let clock = ContinuousClock()
        let initial = clock.now
        await folder.flush()
        print("BENCH initial folder build (\(days)d x \(perDay)): \(LearningBenchmarkJournal.ms(clock.now - initial)) ms")
        var walls: [Double] = [], cpus: [Double] = [], parts: [[Double]] = []
        for i in 0..<12 {
            let cpu0 = LearningBenchmarkJournal.cpuSeconds(), t0 = clock.now
            try f.journal.append(.init(id: "bench-live-\(i)", time: f.clock.now, level: .activity, app: "com.apple.Safari", kind: .activity,
                payload: .init(.init(description: "Switched to Safari", details: ["duration": "12"]))))
            let t1 = clock.now
            f.runtime.learningContextDidChange()
            let t2 = clock.now
            _ = presentation.receivedLearningDeliveryIDs?.count
            let t3 = clock.now
            await folder.settle()
            let t4 = clock.now
            walls.append(LearningBenchmarkJournal.ms(t4 - t0)); cpus.append((LearningBenchmarkJournal.cpuSeconds() - cpu0) * 1000)
            parts.append([t1 - t0, t2 - t1, t3 - t2, t4 - t3].map(LearningBenchmarkJournal.ms))
        }
        let n = Double(walls.count - 2)
        func mean(_ v: [Double]) -> Double { v.dropFirst(2).reduce(0, +) / n }
        print(String(format: "BENCH per event (%dd x %d): wall %.1f ms, cpu %.1f ms; append %.1f, context %.1f, receivedIDs %.1f, folder %.1f",
            days, perDay, mean(walls), mean(cpus), mean(parts.map { $0[0] }), mean(parts.map { $0[1] }), mean(parts.map { $0[2] }), mean(parts.map { $0[3] })))
    }
}
