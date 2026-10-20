import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@Suite @MainActor struct ManagedRestartNoticeTests {
    @Test func resumesQueueOncePerLaunchAndFreshStartsDoNot() async throws {
        let f = try ManagedFixture(auto: false); defer { f.cleanup() }
        let r = try RuntimeFixture(); defer { r.stop() }
        let runtime = ZeusRuntime(cards: r.cards, status: r.status, characters: r.characters, routing: r.routing, clock: f.clock,
            socketPath: f.folder.appendingPathComponent("runtime.sock").path, ledgerURL: f.folder.appendingPathComponent("deliveries.json"),
            connectors: [r.connector], targetIsDead: { _ in false }, managedController: f.controller)
        try runtime.start(); defer { runtime.stop() }
        try await f.settle()
        func checkIn() throws {
            let pane = try #require(f.controller.record?.pane), conversation = try #require(f.controller.record?.conversation)
            runtime.registerSession(.init(id: UUID(), sessionKey: "\(conversation.agent.rawValue):\(conversation.folder)#\(pane.pid).\(pane.startTime)",
                agent: conversation.agent, cwd: conversation.folder, clientName: "Fixture", supportsChannel: false,
                tmuxPane: pane.id, connectedAt: f.clock.now, tmuxSocketPath: pane.socket))
        }
        f.controller.startManagedSession(); try await f.settle(); try checkIn()
        #expect(runtime.ledger?.records.isEmpty == true)
        for expected in 1...2 {
            try await f.prepareIdleRestart()
            f.controller.restartManagedSession(); try await f.settle(); try checkIn()
            runtime.enqueueManagedRestartNotices(); try checkIn()
            let notices = runtime.ledger?.records.filter { $0.delivery.kind == .restart } ?? []
            #expect(notices.count == expected)
            #expect(Set(notices.map { $0.delivery.id }).count == expected)
            #expect(notices.last?.delivery.content.contains("because you pressed Restart Assistant") == true)
            #expect(f.controller.record?.restartNotices?.isEmpty == true)
            #expect(notices.last?.delivery.content.contains("Unprompted messages left today") == false)
        }
        runtime.stop(); try runtime.start(); try await f.settle(); try checkIn()
        #expect(runtime.ledger?.records.filter { $0.delivery.kind == .restart }.count == 2)
        f.controller.startNewManagedConversation(); try await f.settle(); try checkIn()
        #expect(runtime.ledger?.records.filter { $0.delivery.kind == .restart }.count == 2)
        #expect(LearningDeliveryVocabulary.title(kind: .restart) == "Restart notice")
        #expect(ZeusRuntime.sentLearningSummary(kind: "restart", text: "") == "Sent the restart notice")
    }

    @Test func erasingJournalNeverReplaysARestartReceipt() throws {
        let f = try LearningRuntimeFixture(); defer { f.stop() }
        let delivery = Delivery(id: "restart-erased", kind: .restart, sessionKey: "claude:/fixture#123.1", content: "Synthetic restart notice", createdAt: f.clock.now)
        try f.runtime.ledger?.insert(.init(delivery: delivery))
        _ = try f.runtime.acknowledge(ids: [delivery.id], sessionKey: delivery.sessionKey)
        #expect(try f.journal.items(matching: .init()).count == 1)
        try f.journal.delete(.all)
        f.runtime.stop(); try f.runtime.start()
        f.runtime.recordReflectionReceipt(id: delivery.id)
        #expect(try f.journal.items(matching: .init()).isEmpty)
        #expect(f.runtime.ledger?.record(id: delivery.id)?.discardedAt != nil)
    }

    @Test func crashRecoveryNamesTheCauseAndKeepsTheConversation() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        let native = f.controller.record?.conversation?.nativeID
        await f.host.die(); f.controller.refresh(); try await f.settle()
        f.clock.advance(2)
        try await eventually { f.controller.managedStatus == .starting }
        try await f.settle()
        #expect(f.controller.record?.conversation?.nativeID == native)
        #expect(f.controller.record?.restartNotices?.count == 1)
        #expect(f.controller.record?.restartNotices?.first?.reason == "crash recovery")
    }

    @Test func launchOutboxSurvivesDiskReloadAndUnconnectedQuickRestarts() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        #expect(f.controller.record?.restartNotices?.isEmpty != false)
        try await f.prepareIdleRestart()
        f.controller.restartManagedSession(); try await f.settle()
        try await f.prepareIdleRestart()
        f.controller.restartManagedSession(); try await f.settle()
        let restored = try ManagedSessionStore(url: f.folder.appendingPathComponent("state.json")).load()
        #expect(restored.restartNotices?.count == 2)
        #expect(Set(restored.restartNotices?.map(\.id) ?? []).count == 2)
        f.controller.startNewManagedConversation(); try await f.settle()
        #expect(f.controller.record?.restartNotices?.isEmpty != false)
        #expect(f.controller.record?.pendingRestartNotice == nil)
    }
}
