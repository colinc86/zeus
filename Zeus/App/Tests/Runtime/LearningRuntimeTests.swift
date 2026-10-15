import Foundation
import Testing
import ZeusProtocol
import ZeusLink
@testable import Zeus

private struct FixtureLearningRedactor: Redactor {
    func redact(_ text: String) async -> Redacted<String> { .init(text) }
}
@MainActor private final class LearningBox {
    var context = LearningContext()
    var enabled = false
}
@MainActor private final class LearningRuntimeFixture {
    let root = URL(fileURLWithPath: "/tmp/lm2_" + String(UUID().uuidString.prefix(8)))
    let clock = TestRuntimeClock()
    let box = LearningBox()
    let cards: FakeCards
    let connector = FakeConnector()
    let runtime: ZeusRuntime
    let journal: EncryptedJournalStore
    let rules: PersistentRulesStore
    init(learnings: (any LearningsProviding)? = nil) throws {
        clock.now = ISO8601DateFormatter().date(from: "2026-10-14T18:15:00Z") ?? clock.now
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        cards = FakeCards(clock: clock)
        journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: FixtureJournalKey(), calendar: calendar)
        rules = try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        let box = box
        runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: FakeRouting(),
            clock: clock, socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [connector], targetIsDead: { _ in false }, learnings: learnings, rules: rules, journal: journal, redactor: FixtureLearningRedactor(),
            learningContext: { box.context }, reflectionEnabled: { box.enabled }, learningCalendar: calendar)
        try runtime.start()
        runtime.registerSession(.init(id: UUID(), sessionKey: "claude:/fixture#123.1", agent: .claude, cwd: "/fixture", clientName: "Fixture", supportsChannel: true, tmuxPane: nil, connectedAt: clock.now))
    }
    func stop() { runtime.stop(); try? FileManager.default.removeItem(at: root) }
}
@Suite @MainActor struct LearningRuntimeTests {
    @Test func reflectionSamplesScreenDescriptionsNeverFrameMetadataOrBytes() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let frame = Redacted(FrameItem(heic: Data([1, 2, 3]), width: 100, height: 100, boxes: [], appName: "Fixture", windowTitle: "NEVER_FRAME_METADATA"))
        try f.journal.appendFrame(frame, item: .init(id: "frame", time: f.clock.now, level: .screen, kind: .frame, payload: .init(.init(description: "NEVER_FRAME_METADATA"))))
        try f.journal.append(.init(id: "screen-description", time: f.clock.now, level: .screen, kind: .description, payload: .init(.init(description: "Reviewing synthetic screen work", details: ["frame_id": "frame"]))))
        f.box.enabled = true; f.box.context.idleSince = f.clock.now.addingTimeInterval(-601)
        f.runtime.learningContextDidChange()
        try await eventually { !f.connector.deliveries.isEmpty }
        let sent = try #require(f.connector.deliveries.first)
        #expect(sent.kind == .reflection); #expect(sent.content.contains("Reviewing synthetic screen work"))
        #expect(!sent.content.contains("NEVER_FRAME_METADATA")); #expect(!sent.content.contains("heic"))
    }
    @Test func proposalDefaultsValidationConsentAndQuietActions() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let output = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [["sentence": "Stay quiet while tests fail", "trigger": ["state": "tests failing"]], ["sentence": "Send a recap", "kind": "acts"]]], sessionKey: "claude:/fixture#123.1")
        #expect(!output.isError); #expect(f.rules.rules.map(\.status) == [.active, .shadow])
        #expect(f.cards.learningNotices.count == 2)
        f.box.context.states = ["tests failing"]; f.runtime.learningContextDidChange()
        #expect(f.runtime.learningInterruptionHold)
        let invalid = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [["sentence": "invented evidence", "evidence": ["missing"]]]], sessionKey: "claude:/fixture#123.1")
        #expect(invalid.isError); #expect(f.rules.rules.count == 2)
        let unknown = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [["sentence": "bad", "trigger": ["unknown": true]]]], sessionKey: "claude:/fixture#123.1")
        #expect(unknown.isError)
        let read = await f.runtime.callTool("zeus_get_rules", arguments: [:], sessionKey: "claude:/fixture#123.1")
        #expect(!read.isError)
    }
    @Test func holdsOnlyNonurgentPresentationAndReleasesUnreadIDs() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        _ = try f.rules.propose([.init(sentence: "Quiet in editor", trigger: .init(apps: ["com.example.Editor"]))], at: f.clock.now)
        f.box.context.frontmostApp = "com.example.Editor"; f.runtime.learningContextDidChange()
        #expect(f.runtime.learningInterruptionHold)
        f.box.context.frontmostApp = "com.example.Other"; f.runtime.learningContextDidChange()
        f.box.context.frontmostApp = "com.example.Editor" // Context callback has not run yet.
        f.cards.onAdd = { _ in #expect(f.runtime.learningInterruptionHold) }
        _ = await f.runtime.callTool("zeus_say", arguments: ["text": "Normal"], sessionKey: "claude:/fixture#123.1")
        let normal = try #require(f.cards.values.last?.id)
        _ = await f.runtime.callTool("zeus_say", arguments: ["text": "Urgent", "priority": "high"], sessionKey: "claude:/fixture#123.1")
        var released: [String] = []; f.runtime.onLearningHoldCleared = { released = $0 }
        f.box.context.frontmostApp = "com.example.Other"; f.runtime.learningContextDidChange()
        #expect(!f.runtime.learningInterruptionHold); #expect(released == [normal])
    }
    @Test func skipAndIgnoredQuestionCountOnceAcrossReevaluation() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let rule = try #require(f.rules.propose([.init(sentence: "Quiet while tests fail", trigger: .init(state: "tests failing"))], at: f.clock.now).first)
        f.box.context.states = ["tests failing"]; f.runtime.learningContextDidChange()
        _ = await f.runtime.callTool("zeus_ask", arguments: ["text": "Question", "wait_seconds": 0], sessionKey: "claude:/fixture#123.1")
        let card = try #require(f.cards.values.last)
        let response = CardResponse(respondedAt: f.clock.now, device: .mac, skipped: true)
        f.runtime.receivedResponse(card, response: response); f.runtime.receivedResponse(card, response: response)
        #expect(abs((f.rules.rules.first?.confidence ?? 0) - 0.45) < 0.001)
        // Make a separate open question, then let it expire unanswered.
        _ = await f.runtime.callTool("zeus_ask", arguments: ["text": "Ignored", "wait_seconds": 0], sessionKey: "claude:/fixture#123.1")
        f.clock.advance(86401); f.runtime.learningContextDidChange(); f.runtime.learningContextDidChange()
        // Both fake cards remain open; the answered card's durable event must not also count as ignored.
        #expect(f.rules.rules.first(where: { $0.id == rule.id })?.confidence ?? 1 <= 0.35)
    }
    @Test func unconstrainedGuidanceGetsOutcomeFeedbackWithoutHoldingNotifications() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        _ = try f.rules.propose([.init(sentence: "Use concise updates")], at: f.clock.now)
        _ = await f.runtime.callTool("zeus_ask", arguments: ["text": "Question", "wait_seconds": 0], sessionKey: "claude:/fixture#123.1")
        let card = try #require(f.cards.values.last)
        f.runtime.receivedResponse(card, response: .init(respondedAt: f.clock.now, device: .mac, skipped: true))
        #expect(!f.runtime.learningInterruptionHold)
        #expect(abs((f.rules.rules.first?.confidence ?? 0) - 0.45) < 0.001)
    }
    @Test func shadowApprovalAndSettingsApprovalReplaceActionWithUndo() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        _ = await f.runtime.callTool("zeus_propose_rules", arguments: ["rules": [["sentence": "Send a recap", "kind": "acts"], ["sentence": "Use short updates"]]], sessionKey: "claude:/fixture#123.1")
        let rule = try #require(f.rules.rules.first), id = "shadow:" + rule.id
        #expect(f.cards.learningNotices.contains { $0.summary == "2 new rules" })
        #expect(f.cards.learningNotices.first { $0.id == id }?.summary == "I'd have acted on “Send a recap”")
        let staleOK = try #require(f.cards.learningActions[id]); staleOK()
        #expect(f.rules.rules.first?.status == .active)
        #expect(f.cards.learningNotices.first { $0.id == id }?.actionTitle == "Undo")
        staleOK(); #expect(f.rules.rules.first?.status == .active)
        let undo = try #require(f.cards.learningActions[id]); undo()
        #expect(f.rules.rules.first?.status == .shadow)
        #expect(abs((f.rules.rules.first?.confidence ?? 0) - 0.4) < 0.001)
        try f.rules.setStatus(.active, id: rule.id, at: f.clock.now); f.runtime.learningContextDidChange()
        #expect(f.cards.learningNotices.first { $0.id == id }?.summary == "OK. I'll do that from now on.")
        try f.rules.setStatus(.proposed, id: rule.id, at: f.clock.now); f.runtime.learningContextDidChange()
        #expect(f.cards.learningNotices.first { $0.id == id }?.summary == "Got it. I won't.")
        #expect(f.cards.learningActions[id] == nil)
        try f.rules.setStatus(.retired, id: rule.id, at: f.clock.now); f.runtime.learningContextDidChange()
        #expect(f.cards.learningNotices.first { $0.id == id }?.summary == "Retired: “Send a recap”")
        #expect(f.cards.learningNotices.first { $0.id == id }?.actionTitle == "Review")
        var reviewed: String?; f.runtime.onReviewRule = { reviewed = $0 }
        f.cards.learningActions[id]?(); #expect(reviewed == rule.id)
    }
    @Test func deletingEvidenceErasesPendingReflectionBodyWithoutRepeatingTheDay() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        f.connector.available = false
        try f.journal.append(.init(id: "evidence", time: f.clock.now, level: .focus, kind: .focus, payload: .init(.init(description: "Synthetic activity"))))
        f.box.context.idleSince = f.clock.now.addingTimeInterval(-601); f.box.enabled = true; f.runtime.learningContextDidChange()
        try await eventually { f.runtime.ledger?.records.count == 1 }
        try f.journal.delete(.all); f.runtime.learningContextDidChange()
        let record = try #require(f.runtime.ledger?.records.first)
        #expect(record.delivery.content.isEmpty && record.discardedAt != nil)
        try f.journal.append(.init(id: "new", time: f.clock.now, level: .focus, kind: .focus, payload: .init(.init(description: "New activity"))))
        f.runtime.learningContextDidChange(); for _ in 0..<20 { await Task.yield() }
        #expect(f.runtime.ledger?.records.count == 1)
    }
    @Test func learningLedgerRecordsExactWrittenPayloadAndNeverPreparation() async throws {
        let learnings = FakeLearnings(), f = try LearningRuntimeFixture(learnings: learnings); defer { f.stop() }
        let learning = Learning(id: "daily", kind: .digest, createdAt: f.clock.now, text: "A synthetic day ‹email›.")
        learnings.items = [learning]
        let prepared = await f.runtime.callTool("zeus_get_learnings", arguments: [:], sessionKey: "claude:/fixture#123.1", deferResultCommit: true)
        #expect(!prepared.isError)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        do {
            _ = try await client.start(hello: .init(agent: .claude, pid: 17, ppid: 19, cwd: "/fixture", client: .init(name: "Test", version: "1"), capabilities: .init(channel: true, toolResultWritten: true), parentStartTime: 3), onPush: { _ in })
            let reply = try await client.requestTool(name: "zeus_get_learnings")
            #expect(try f.journal.items(matching: .init()).isEmpty)
            try await client.reportToolResultWritten(callID: reply.callID)
            try await eventually { (try? f.journal.items(matching: .init()).count) == 1 }
            let receipt = try #require(f.journal.items(matching: .init()).first)
            #expect(receipt.kind == .sentToAssistant && receipt.payload.value.text == learning.text)
            #expect(receipt.payload.value.details["kind"] == "digest")
            #expect(receipt.payload.value.details["sessionLabel"] == "Claude · Assistant")
            #expect(!String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).contains("/fixture"))
            await client.stop()
        } catch { await client.stop(); throw error }
    }
    @Test func learningNotificationIsAnActualReceiptWithoutConsumingPolling() async throws {
        let learnings = FakeLearnings(), f = try LearningRuntimeFixture(learnings: learnings); defer { f.stop() }
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        var received: [BridgeLearning] = []
        do {
            _ = try await client.start(hello: .init(agent: .claude, pid: 17, ppid: 19, cwd: "/fixture", client: .init(name: "Test", version: "1"), capabilities: .init(channel: true, learningNotifications: true), parentStartTime: 3), onPush: { _ in }, onLearning: { value in await MainActor.run { received.append(value) } })
            try await eventually { f.runtime.bridges.count == 1 }
            learnings.add(.init(id: "note", kind: .moment, createdAt: f.clock.now, text: "Back from a synthetic break."))
            try await eventually { received.count == 1 && ((try? f.journal.items(matching: .init()).count) == 1) }
            #expect(learnings.readIDs.isEmpty)
            #expect(try f.journal.items(matching: .init()).first?.payload.value.text == received.first?.text)
            await client.stop()
        } catch { await client.stop(); throw error }
    }
    @Test func outcomeFeedbackEntersJournalOnlyWithCaptureConsent() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let own = try f.rules.addOwn(.init(sentence: "Short updates"), at: f.clock.now)
        try f.rules.edit(id: own.id, sentence: "Concise updates", trigger: .init(), at: f.clock.now)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        f.box.enabled = true
        try f.rules.setStatus(.retired, id: own.id, at: f.clock.now)
        try f.rules.edit(id: own.id, sentence: "Brief updates", trigger: .init(), at: f.clock.now)
        _ = await f.runtime.callTool("zeus_ask", arguments: ["text": "Synthetic private question text", "wait_seconds": 0], sessionKey: "claude:/fixture#123.1")
        let card = try #require(f.cards.values.last)
        f.runtime.receivedResponse(card, response: .init(respondedAt: f.clock.now, device: .mac, skipped: true))
        f.runtime.learningTrackedChange(AppChange(summary: "A synthetic change", undoTitle: "Undo", undo: {})).undo()
        var query = JournalQuery(); query.kinds = [.outcome]
        let feedback = try f.journal.items(matching: query)
        #expect(feedback.count == 4)
        #expect(!String(decoding: try JSONEncoder().encode(feedback), as: UTF8.self).contains("Synthetic private question text"))
        try f.journal.delete(.all); f.runtime.learningContextDidChange()
        for _ in 0..<20 { await Task.yield() }
        #expect(try f.journal.items(matching: .init()).isEmpty)
    }
    @Test func launchCatchupAfterEveningUsesLatestRecordedDayAndStillSendsOnlyOnceToday() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        try f.journal.append(.init(id: "earlier", time: f.clock.now.addingTimeInterval(-3*86400), level: .focus, kind: .focus, payload: .init(.init(description: "Earlier synthetic activity"))))
        f.box.enabled = true; f.runtime.learningContextDidChange()
        try await eventually { f.connector.deliveries.count == 1 }
        #expect(f.connector.deliveries[0].meta["reflection_day"] == "20261011")
        try f.journal.append(.init(id: "today", time: f.clock.now, level: .focus, kind: .focus, payload: .init(.init(description: "Today's activity"))))
        f.box.context.idleSince = f.clock.now.addingTimeInterval(-601); f.runtime.learningContextDidChange()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.runtime.ledger?.records.count == 1)
    }
    @Test func reflectionRequiresExplicitCaptureConsentAndIsDurableOncePerDay() async throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        try f.journal.append(.init(id: "evidence", time: f.clock.now, level: .focus, app: "com.example.Editor", kind: .focus,
            payload: .init(.init(description: "Editing a test document"))))
        f.box.context.idleSince = f.clock.now.addingTimeInterval(-601)
        f.runtime.learningContextDidChange(); for _ in 0..<10 { await Task.yield() }
        #expect(f.connector.deliveries.isEmpty)
        f.box.enabled = true; f.runtime.learningContextDidChange()
        try await eventually { f.connector.deliveries.contains { $0.kind == .reflection } }
        let delivery = try #require(f.connector.deliveries.first)
        #expect(delivery.meta["kind"] == "reflection")
        #expect(delivery.content.contains("evidence"))
        try await eventually { (try? f.journal.items(matching: .init()).contains { $0.kind == .sentToAssistant }) == true }
        _ = try f.runtime.acknowledge(ids: [delivery.id], sessionKey: delivery.sessionKey)
        f.runtime.stop(); try f.runtime.start(); f.runtime.registerSession(.init(id: UUID(), sessionKey: delivery.sessionKey, agent: .claude, cwd: "/fixture", clientName: "Fixture", supportsChannel: true, tmuxPane: nil, connectedAt: f.clock.now))
        f.runtime.learningContextDidChange(); for _ in 0..<20 { await Task.yield() }
        #expect(f.connector.deliveries.count == 1)
        #expect(f.runtime.userMessageDeliveries.isEmpty)
    }
}
