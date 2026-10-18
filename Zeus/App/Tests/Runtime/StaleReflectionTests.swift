import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@Suite @MainActor struct StaleReflectionTests {
    private let key = "claude:/fixture#123.1"
    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @Test(arguments: [false, true])
    func upgradeReplacesFourRawReflectionsWithOneCatchUpPointer(dashedLegacyID: Bool) async throws {
        let runner = PointerPasteRunner()
        await runner.resume()
        let f = try LearningRuntimeFixture(calendar: ReflectionPatternTests.calendar,
            deliveryConnector: TmuxConnector(executable: URL(fileURLWithPath: "/fixture/tmux"), runner: runner))
        defer { f.stop() }
        f.runtime.stop()
        f.clock.now = try date("2026-10-18T14:00:00Z")
        let ledger = try DeliveryLedger(location: f.root.appendingPathComponent("deliveries.json"))
        let times = ["2026-10-15T03:48:00Z", "2026-10-16T03:31:00Z", "2026-10-17T02:40:00Z", "2026-10-18T01:21:00Z"]
        let lengths = [15242, 11802, 12032, 12079]
        for index in 0..<4 {
            let day = "2026-10-\(14 + index)"
            let id = "d_reflection_" + (dashedLegacyID ? day : day.replacingOccurrences(of: "-", with: ""))
            let header = "Zeus reflection for \(day). This is a redacted local summary, not a new user request.\n2026-10-14T18:00:00Z id=synthetic app=fixture "
            var delivery = Delivery(id: id, kind: .reflection, sessionKey: key,
                content: header + String(repeating: "x", count: lengths[index] - header.count), createdAt: try date(times[index]))
            delivery.meta = ["reflection_day": day, "evidence": "old"]
            delivery.attempts = 5; delivery.failedAt = delivery.createdAt
            try ledger.insert(.init(delivery: delivery, queueReason: ConnectorError.inputTooLong.localizedDescription))
        }
        let (_, rows) = ReflectionPatternTests.fixture(days: 20)
        for row in rows { try f.journal.append(row) }
        f.box.enabled = true
        let settings = try #require(f.runtime.routing as? FakeRouting)
        settings.deliveryMethod = .tmux
        try f.runtime.start()
        f.runtime.registerSession(.init(id: UUID(), sessionKey: key, agent: .claude, cwd: "/fixture",
            clientName: "Fixture", supportsChannel: false, tmuxPane: "%0", connectedAt: f.clock.now,
            tmuxSocketPath: f.root.appendingPathComponent("fixture.sock").path))
        f.runtime.learningContextDidChange()
        try await eventually { f.runtime.ledger?.records.contains { $0.delivery.meta["source_hash"] != nil && $0.transportDeliveredAt != nil } == true }
        let records = try #require(f.runtime.ledger?.records)
        let old = records.filter { $0.delivery.meta["source_hash"] == nil }
        #expect(old.count == 4 && old.allSatisfy { $0.delivery.meta["discard_reason"] == "superseded" && $0.transportDeliveredAt == nil })
        let fresh = try #require(records.first { $0.delivery.meta["source_hash"] != nil })
        #expect(fresh.delivery.meta["reflection_day"] == "20261017")
        #expect(fresh.delivery.meta["tmux_pointer"] == "true")
        #expect(fresh.delivery.content.contains("Notes/patterns.md"))
        #expect(records.filter { $0.isPending }.count == 1)
        #expect(await runner.loads == 1)
        #expect(await runner.enters == 1)
        #expect(f.cards.learningNotices.allSatisfy { !$0.summary.hasPrefix("Not sent:") })
        #expect(f.cards.values.isEmpty)
        #expect(try f.runtime.acknowledge(ids: Set(old.map { $0.delivery.id }), sessionKey: key).isEmpty)
        #expect(f.runtime.ledger?.record(id: fresh.delivery.id)?.delivery.ackedAt == nil)
        let fetched = await f.runtime.callTool("zeus_get_learnings", arguments: ["id": .string(fresh.delivery.id)], sessionKey: key)
        #expect(fetched.structured?["delivery"]?["content"] == .string(fresh.delivery.content))
        _ = try f.runtime.acknowledge(ids: [fresh.delivery.id], sessionKey: key)
        f.runtime.stop(); try f.runtime.start()
        f.runtime.registerSession(.init(id: UUID(), sessionKey: key, agent: .claude, cwd: "/fixture",
            clientName: "Fixture", supportsChannel: false, tmuxPane: "%0", connectedAt: f.clock.now))
        f.runtime.learningContextDidChange()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.runtime.ledger?.records.filter { $0.delivery.meta["source_hash"] != nil }.count == 1)
        #expect(await runner.enters == 1)
    }

    @Test func supersededLegacyCreatedTodayDoesNotBlockCatchUp() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        f.connector.available = false
        var old = Delivery(id: "d_reflection_20261013", kind: .reflection, sessionKey: key,
            content: "This is a redacted local summary, not a new user request.", createdAt: f.clock.now)
        old.meta["reflection_day"] = "20261013"
        try f.runtime.ledger?.insert(.init(delivery: old))
        try f.journal.append(.init(id: "yesterday", time: f.clock.now.addingTimeInterval(-86400),
            level: .focus, kind: .focus, payload: .init(.init(description: "Synthetic work"))))
        f.box.enabled = true
        f.runtime.learningContextDidChange()
        try await eventually { f.runtime.ledger?.record(id: "d_reflection_20261013_patterns") != nil }
        #expect(f.runtime.ledger?.record(id: old.id)?.delivery.meta["discard_reason"] == "superseded")
        #expect(f.cards.learningNotices.isEmpty)
    }

    @Test func newlyPreparedBriefSupersedesYesterdayBeforePolicyErasure() throws {
        let name = "fx11-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MorningBriefSettings(defaults: defaults); settings.enabled = true
        let f = try LearningRuntimeFixture(morningBriefSettings: settings); defer { f.stop() }
        var old = Delivery(id: "brief_old", kind: .brief, sessionKey: key, content: "Yesterday's brief",
            createdAt: f.clock.now.addingTimeInterval(-86400))
        old.meta["brief_day"] = f.runtime.proactiveDay(old.createdAt)
        try f.runtime.ledger?.insert(.init(delivery: old))
        f.runtime.noteProactiveActivity(at: f.clock.now)
        #expect(f.runtime.ledger?.record(id: old.id)?.delivery.meta["discard_reason"] == "superseded")
        #expect(f.runtime.ledger?.records.filter { $0.delivery.kind == .brief && $0.isPending }.count == 1)
        #expect(f.cards.learningNotices.isEmpty)
    }

    @Test func failedErasureWriteCannotExposeDiscardedTextAgain() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let old = Delivery(id: "erased", kind: .brief, sessionKey: key, content: "Exact private request", createdAt: f.clock.now.addingTimeInterval(-3 * 86400))
        try f.runtime.ledger?.insert(.init(delivery: old))
        f.runtime.expireStaleLearningDeliveries()
        #expect(f.runtime.discardedLearningDeliveries.count == 1)
        let file = f.root.appendingPathComponent("deliveries.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        f.runtime.eraseLearningDeliveries(ids: [old.id])
        #expect(f.runtime.ledger?.record(id: old.id)?.delivery.content == old.content)
        #expect(f.runtime.learningError != nil)
        f.runtime.publishPendingLearnings(f.runtime.ledger?.records ?? [])
        #expect(f.runtime.discardedLearningDeliveries.isEmpty)
    }

    @Test(arguments: [Delivery.Kind.reflection, .brief])
    func appAttachedRewritesExistingLineAndRetainsSevenDayEvidence(kind: Delivery.Kind) throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let cards = CardStore(fileURL: f.root.appendingPathComponent("app-cards.json"))
        let model = LearningDeliveryModel(cards: cards, source: { f.runtime }, clock: { f.clock.now })
        let old = Delivery(id: "old", kind: kind, sessionKey: key, content: "Exact old text\nSecond line", createdAt: f.clock.now.addingTimeInterval(-86400))
        try f.runtime.ledger?.insert(.init(delivery: old))
        f.runtime.publishPendingLearnings(f.runtime.ledger?.records ?? []); model.reconcile()
        #expect(cards.notices.first?.summary.hasSuffix("ready for your assistant") == true)
        var fresh = old; fresh.id = "fresh"; fresh.createdAt = f.clock.now
        try f.runtime.ledger?.insert(.init(delivery: fresh))
        f.runtime.expireStaleLearningDeliveries(); model.reconcile()
        let line = try #require(cards.notices.first { $0.id == "n_old" })
        #expect(line.summary == DiscardedLearningDelivery.caption(kind: kind, reason: .superseded))
        #expect(line.detail == old.content && line.createdAt == old.createdAt)
        #expect(model.discarded.map(\.id) == ["old"])
        #expect(model.discarded.first?.queueReason == f.runtime.ledger?.record(id: "old")?.queueReason)
        #expect(cards.removeNotice(id: "n_old"))
        model.reconcile()
        #expect(!cards.notices.contains { $0.id == "n_old" })
        f.clock.now = f.clock.now.addingTimeInterval(7 * 86400)
        f.runtime.publishPendingLearnings(f.runtime.ledger?.records ?? []); model.reconcile()
        #expect(model.discarded.isEmpty)
    }

    @Test(arguments: [Delivery.Kind.reflection, .brief])
    func newestExpiresOnceAndSupersededNeverNotifies(kind: Delivery.Kind) throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        for (id, age) in [("older", 5.0), ("newer", 4.0)] {
            let d = Delivery(id: id, kind: kind, sessionKey: key, content: "Synthetic request", createdAt: f.clock.now.addingTimeInterval(-age * 86400))
            try f.runtime.ledger?.insert(.init(delivery: d))
        }
        f.runtime.expireStaleLearningDeliveries()
        #expect(f.runtime.ledger?.record(id: "older")?.delivery.meta["discard_reason"] == "superseded")
        #expect(f.runtime.ledger?.record(id: "newer")?.delivery.meta["discard_reason"] == "expired")
        #expect(f.cards.learningNotices.isEmpty) // App presentation owns both transitions.
        #expect(f.runtime.discardedLearningDeliveries.count == 2)
        f.cards.learningNotices.removeAll() // The user dismisses the notice.
        f.runtime.expireStaleLearningDeliveries()
        f.runtime.stop(); try f.runtime.start()
        #expect(f.cards.learningNotices.isEmpty)
    }

    @Test(arguments: [Delivery.Kind.reflection, .brief])
    func newerRequestQuietlyCancelsInFlightOlderAndItsLateReceipt(kind: Delivery.Kind) async throws {
        let f = try LearningRuntimeFixture(); defer { f.connector.release(); f.stop() }
        f.connector.hold = true
        let older = Delivery(id: "older", kind: kind, sessionKey: key, content: "Old request", createdAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: older))
        // Brief routing is separately consent-gated; emulate its already-started task.
        let task = Task<MessageSendResult, Never> {
            do { try await f.connector.deliver(older, to: connectorSession(agent: .claude), bridge: nil, routing: f.runtime.routing) }
            catch { return .queued(reason: "Cancelled") }
            return .delivered
        }
        f.runtime.sends[older.id] = task
        try await eventually { !f.connector.waits.isEmpty }
        var newer = older; newer.id = "newer"; newer.createdAt = f.clock.now.addingTimeInterval(1)
        try f.runtime.ledger?.insert(.init(delivery: newer))
        f.runtime.expireStaleLearningDeliveries()
        #expect(task.isCancelled)
        #expect(f.runtime.ledger?.record(id: "older")?.delivery.meta["discard_reason"] == "superseded")
        #expect(f.runtime.ledger?.record(id: "newer")?.isPending == true)
        #expect(try f.runtime.acknowledge(ids: ["older"], sessionKey: key).isEmpty)
        f.runtime.recordReflectionReceipt(id: "older")
        #expect(try f.journal.items(matching: .init()).isEmpty)
        #expect(f.cards.learningNotices.isEmpty)
    }
}
