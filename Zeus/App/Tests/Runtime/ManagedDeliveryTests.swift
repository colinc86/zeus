import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
final class ManagedRecordingConnector: DeliveryConnector {
    var deliveries: [Delivery] = []
    var targets: [String?] = []
    var sockets: [String?] = []
    func canDeliver(to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) -> Bool { routing.deliveryMethod == .tmux }
    func deliver(_ delivery: Delivery, to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) async throws {
        try await (routing as? DeliveryRoutingContext)?.managedValidateDestination?()
        deliveries.append(delivery); targets.append(routing.tmuxTarget); sockets.append((routing as? DeliveryRoutingContext)?.tmuxSocketPath)
    }
}

@MainActor
struct ManagedDeliveryFixture {
    let managed: ManagedFixture
    let cards: FakeCards
    let status = FakeStatus()
    let routing = FakeRouting()
    let tmux = ManagedRecordingConnector()
    let runtime: ZeusRuntime
    init(agent: AgentKind = .claude, tmuxConnector: (any DeliveryConnector)? = nil) throws {
        let f = try ManagedFixture(agent: agent); managed = f
        cards = FakeCards(clock: f.clock)
        routing.deliveryMethod = .polling; routing.tmuxTarget = "%wrong"
        runtime = .init(cards: cards, status: status, characters: FakeCharacters(), routing: routing, clock: f.clock,
            socketPath: f.folder.appendingPathComponent("runtime.sock").path, ledgerURL: f.folder.appendingPathComponent("deliveries.json"),
            connectors: [ChannelDeliveryConnector(), tmuxConnector ?? tmux], targetIsDead: { _ in false }, managedController: f.controller)
    }
    func start() async throws {
        try runtime.start(); try await managed.settle()
        let pane = try #require(managed.controller.record?.pane)
        let agent = try #require(managed.controller.record?.conversation?.agent)
        runtime.registerSession(.init(id: UUID(), sessionKey: "\(agent.rawValue):\(managed.folder.path)#\(pane.pid).\(pane.startTime)", agent: agent,
            cwd: managed.folder.path, clientName: nil, supportsChannel: true, tmuxPane: pane.id, connectedAt: managed.clock.now, tmuxSocketPath: pane.socket))
    }
    func idle() async throws {
        managed.clock.advance(10, wake: false)
        let agent = try #require(managed.controller.record?.conversation?.agent)
        let fixture = agent == .claude ? "claude-idle" : agent == .codex ? "codex-ready" : "opencode-ready"
        await managed.host.setSnapshot(try managedSnapshot(fixture))
        managed.controller.refresh(); try await managed.settle()
    }
    func cleanup() { runtime.stop(); managed.cleanup() }
}

@MainActor
struct ManagedDeliveryTests {
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func managedIgnoresAdvancedDeliveryAndPaneAndWaitsForIdle(agent: AgentKind) async throws {
        let f = try ManagedDeliveryFixture(agent: agent); defer { f.cleanup() }
        if agent == .opencode { await f.managed.finder.setID("ses_managed") }
        try await f.start()
        _ = await f.runtime.sendUserMessage("Hold until idle", deliveryID: "d_managed")
        #expect(f.tmux.deliveries.isEmpty)
        #expect(f.runtime.ledger?.record(id: "d_managed")?.delivery.attempts == 0)
        try await f.idle()
        try await eventually { f.tmux.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.tmux.targets == [f.managed.controller.record?.pane?.id])
        #expect(f.tmux.sockets == [f.managed.controller.record?.pane?.socket])
        #expect(f.runtime.managedStatus == .running(.idle))
    }
    @Test func blockedCardIsOneTerminalActionAndResolvesWithoutDelivery() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let blocked = try managedSnapshot("claude-blocked-permission")
        await f.managed.host.setSnapshot(blocked)
        for _ in 0..<3 { f.managed.controller.refresh(); try await f.managed.settle() }
        let card = try #require(f.cards.values.first)
        #expect(f.cards.values.count == 1 && card.priority == .high && card.mood == .alert)
        #expect(card.options.contains { $0.id == "open-terminal" } && f.status.state == .alert)
        for _ in 0..<2 {
            f.cards.respond(id: card.id, option: "open-terminal")
            try await f.managed.settle()
            #expect(f.cards.card(id: card.id)?.status == .open)
            #expect(f.cards.card(id: card.id)?.response == nil)
        }
        #expect(f.managed.terminal.files.count == 2)
        #expect(f.runtime.ledger?.records.isEmpty == true && f.tmux.deliveries.isEmpty)
        #expect(f.runtime.responseJournal?.intents.isEmpty == true)
        // A transient blank capture never resolves/recreates a confirmed permission card.
        let previousBlock = f.runtime.managedStatus
        await f.managed.host.setSnapshot(.init(screen: "", inputMetadata: "0|0|120|0|1"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        #expect(f.runtime.managedStatus == previousBlock)
        #expect(f.cards.card(id: card.id)?.status == .open && f.cards.values.count == 1)
        #expect(!f.managed.controller.canAcceptInput && f.status.state == .alert)
        await f.managed.host.setSnapshot(blocked)
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        #expect(f.cards.values.count == 1)
        _ = await f.runtime.sendUserMessage("Saved while blocked", deliveryID: "d_wait")
        #expect(f.tmux.deliveries.isEmpty)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-idle"))
        f.managed.controller.refresh(); try await f.managed.settle()
        try await eventually { f.tmux.deliveries.count == 1 }
        #expect(f.cards.card(id: card.id)?.status == .answered)
        #expect(f.cards.card(id: card.id)?.body == "Answered in Terminal")
        #expect(f.cards.card(id: card.id)?.options.isEmpty == true && f.status.state == nil)
        await f.managed.host.setSnapshot(blocked)
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        #expect(f.cards.values.count == 2 && f.cards.values.last?.id != card.id)
    }
    @Test func claudeReadinessRequiresExplicitAckAndFallbackAtThirtySecondsUsesSameID() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let pane = try #require(f.managed.controller.record?.pane)
        let client = BridgeClient(socketPath: f.runtime.socketPath)
        var pushes: [AgentPush] = []
        let hello = BridgeHello(agent: .claude, pid: 2, ppid: pane.pid, cwd: f.managed.folder.path,
            client: .init(name: "Managed test", version: "1"), capabilities: .init(channel: true), tmuxPane: pane.id,
            parentStartTime: pane.startTime, tmuxSocketPath: pane.socket)
        do {
            _ = try await client.start(hello: hello, onPush: { push in
                await MainActor.run { pushes.append(push) }
                try? await client.reportPushWritten(deliveryID: push.deliveryID)
            })
            try await eventually { pushes.count == 1 }
            let probe = try #require(pushes.first?.deliveryID)
            #expect(!f.runtime.managedChannelReady.contains(hello.sessionKey))
            #expect(await f.runtime.sendUserMessage("tmux before evidence", deliveryID: "d_before") == .delivered)
            #expect(f.tmux.deliveries.map(\.id) == ["d_before"])
            _ = try await client.callTool(name: "zeus_get_responses")
            try await eventually { f.runtime.ledger?.record(id: "d_before")?.delivery.ackedAt != nil }
            #expect(!f.runtime.managedChannelReady.contains(hello.sessionKey))
            _ = try await client.callTool(name: "zeus_ack", arguments: ["delivery_ids": [.string(probe)]])
            #expect(f.runtime.managedChannelReady.contains(hello.sessionKey))
            #expect(await f.runtime.sendUserMessage("channel after evidence", deliveryID: "d_channel") == .delivered)
            try await eventually { pushes.count == 2 && f.runtime.sends.isEmpty }
            #expect(pushes.last?.deliveryID == "d_channel")
            #expect(f.tmux.deliveries.count == 1)
            f.managed.clock.advance(29); f.runtime.processDueDeliveries()
            #expect(f.tmux.deliveries.count == 1)
            f.managed.clock.advance(1); f.runtime.processDueDeliveries()
            try await eventually { f.tmux.deliveries.count == 2 && f.runtime.sends.isEmpty }
            #expect(f.tmux.deliveries.last?.id == "d_channel")
            #expect(!f.runtime.managedChannelReady.contains(hello.sessionKey))
            _ = try await client.callTool(name: "zeus_ack", arguments: ["delivery_ids": ["d_channel"]])
            #expect(!f.runtime.managedChannelReady.contains(hello.sessionKey), "A pane ack after fallback must not revive the failed channel")
            // Fresh positive readiness evidence can still restore channel delivery.
            _ = try await client.callTool(name: "zeus_ack", arguments: ["delivery_ids": [.string(probe)]])
            #expect(await f.runtime.sendUserMessage("ack before fallback", deliveryID: "d_acked") == .delivered)
            _ = try await client.callTool(name: "zeus_ack", arguments: ["delivery_ids": ["d_acked"]])
            f.managed.clock.advance(180); f.runtime.processDueDeliveries()
            #expect(f.tmux.deliveries.count == 2 && pushes.count == 3)
            await client.stop()
        } catch { await client.stop(); throw error }
    }
}

extension ManagedDeliveryTests {
    /// Opt-in M0 localhost-model fixture, never a human pane or the default tmux server.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_M2B_OPENCODE_SOCKET"] != nil))
    func realOpenCodeReceivesVerifiedLongTmuxParagraph() async throws {
        let socket = try #require(ProcessInfo.processInfo.environment["ZEUS_M2B_OPENCODE_SOCKET"])
        try #require(socket.hasPrefix("/tmp/zm0_"), "Only the isolated M0 harness is accepted")
        let tmux = try #require(TmuxExecutable.resolve())
        let routing = FakeRouting(); routing.deliveryMethod = .polling; routing.tmuxTarget = "%wrong"
        let context = DeliveryRoutingContext(settings: routing, assistantSessionKey: "managed", tmuxSocketPath: socket)
        context.managedMethod = .tmux; context.managedPane = "%0"; context.managedInputAllowed = { true }
        let session = ConnectedSession(id: UUID(), sessionKey: "managed", agent: .opencode, cwd: "/fixture", clientName: nil,
            supportsChannel: false, tmuxPane: "%0", connectedAt: Date(), tmuxSocketPath: socket)
        let delivery = Delivery(id: "d_long_managed", kind: .userMessage, sessionKey: "managed",
            content: String(repeating: "A useful long message about the assistant. ", count: 9))
        try await TmuxConnector(executable: tmux).deliver(delivery, to: session, bridge: nil, routing: context)
    }
}

extension ManagedDeliveryTests {
    @Test func persistedTerminalActionStaysOpenAndContinuousBlockSurvivesAppRelaunch() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        let path = f.folder.appendingPathComponent("cards.json")
        let cards = CardStore(fileURL: path, clock: { f.clock.now })
        let routing = FakeRouting(); let status = AvatarStatusModel(cards: cards, clock: { f.clock.now })
        func makeRuntime(_ controller: ManagedSessionController) -> ZeusRuntime {
            .init(cards: cards, status: status, characters: FakeCharacters(), routing: routing, clock: f.clock,
                socketPath: f.folder.appendingPathComponent("runtime.sock").path, ledgerURL: f.folder.appendingPathComponent("deliveries.json"),
                connectors: [], targetIsDead: { _ in false }, managedController: controller)
        }
        let first = makeRuntime(f.controller); try first.start()
        defer { first.stop() }
        try await f.settle(); f.clock.advance(10, wake: false)
        await f.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.controller.refresh(); try await f.settle() }
        let card = try #require(cards.cards.first)
        cards.markSeen(id: card.id)
        cards.setConversationOpen(true)
        #expect(status.state == .alert && status.badgeCount == 0)
        let before = try Data(contentsOf: path)
        #expect(cards.respond(id: card.id, response: .init(optionID: "open-terminal", device: .mac)))
        try await f.settle()
        #expect(try Data(contentsOf: path) == before) // No answered snapshot is ever written.
        #expect(cards.card(id: card.id)?.status == .open && cards.card(id: card.id)?.response == nil)
        #expect(f.terminal.files.count == 1 && first.ledger?.records.isEmpty == true)
        cards.setConversationOpen(false)
        #expect(status.state == .alert)
        first.stop()
        #expect(cards.card(id: card.id)?.status == .open)
        let next = ManagedSessionController(configuration: { f.config.value }, stateURL: f.folder.appendingPathComponent("state.json"),
            bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: "unused", executables: f.controller.executables,
            hosting: f.host, clock: f.clock, terminalOpener: f.terminal)
        let second = makeRuntime(next); try second.start(); defer { second.stop() }
        try await eventually { !next.isBusy }
        await f.host.setSnapshot(.init(screen: "", inputMetadata: "0|0|120|0|1"))
        for _ in 0..<2 { next.refresh(); try await eventually { !next.isBusy } }
        #expect(cards.card(id: card.id)?.status == .open)
        #expect(!next.mayResolveBlockedCard)
        await f.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { next.refresh(); try await eventually { !next.isBusy } }
        #expect(cards.cards.count == 1 && cards.cards.first?.id == card.id)
        f.clock.advance(10, wake: false); next.refresh(); try await eventually { !next.isBusy }
        #expect(second.managedBlockedCardID == card.id && cards.cards.count == 1)
        await f.host.setSnapshot(try managedSnapshot("claude-idle")); next.refresh(); try await eventually { !next.isBusy }
        #expect(cards.card(id: card.id)?.body == "Answered in Terminal")
        #expect(cards.card(id: card.id)?.status == .answered && cards.card(id: card.id)?.response == nil)
        #expect(status.state == .idle)
    }
}

extension ManagedDeliveryTests {
    @Test func durableChannelDeadlineWaitsAcrossRelaunchAndBlock() async throws {
        let f = try ManagedDeliveryFixture(); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        let sent = f.managed.clock.now
        let delivery = Delivery(id: "d_recovered_channel", kind: .userMessage, sessionKey: key, content: "Keep this ID",
            meta: ["managed_channel_sent_at": String(sent.timeIntervalSince1970)], createdAt: sent, attempts: 1, lastAttemptAt: sent)
        try f.runtime.ledger?.insert(.init(delivery: delivery, userText: "Keep this ID", transportDeliveredAt: sent))
        f.managed.clock.advance(15, wake: false)
        f.runtime.stop(); try f.runtime.start(); try await f.managed.settle()
        try await f.start() // Re-register the existing process bridge; never replay early on connect.
        try await f.idle() // Now 25 seconds after the push, with adoption grace elapsed.
        #expect(f.tmux.deliveries.isEmpty)
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.meta["managed_channel_fallback"] == nil)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        f.managed.clock.advance(5, wake: false)
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        f.runtime.processDueDeliveries()
        #expect(f.tmux.deliveries.isEmpty)
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.meta["managed_channel_fallback"] == "true")
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.attempts == 1)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-idle")); f.managed.controller.refresh(); try await f.managed.settle()
        try await eventually { f.tmux.deliveries.count == 1 && f.runtime.sends.isEmpty }
        #expect(f.tmux.deliveries.first?.id == delivery.id)
        #expect(f.runtime.ledger?.record(id: delivery.id)?.delivery.attempts == 2)
    }
}

@MainActor
struct ManagedBlockedPersistenceTests {
    @Test func blockedCardCreationRetriesSameIdentityAfterDiskRepair() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        let path = f.folder.appendingPathComponent("cards.json")
        let cards = CardStore(fileURL: path, clock: { f.clock.now })
        let status = FakeStatus()
        let runtime = ZeusRuntime(cards: cards, status: status, characters: FakeCharacters(), routing: FakeRouting(),
            clock: f.clock, socketPath: f.folder.appendingPathComponent("runtime.sock").path,
            ledgerURL: f.folder.appendingPathComponent("deliveries.json"), connectors: [], managedController: f.controller)
        try runtime.start(); defer { runtime.stop() }
        try await f.settle(); f.clock.advance(10, wake: false)
        // An obstructing directory deterministically rejects the atomic cards snapshot.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        await f.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.controller.refresh(); try await f.settle() }
        let id = try #require(runtime.managedBlockedCardID)
        #expect(cards.cards.isEmpty && cards.persistenceError != nil)
        #expect(status.state == .alert)
        try FileManager.default.removeItem(at: path)
        for _ in 0..<3 { f.controller.refresh(); try await f.settle() }
        #expect(cards.cards.map(\.id) == [id])
        #expect(CardStore(fileURL: path).cards.map(\.id) == [id])
        #expect(cards.cards.first?.status == .open)
        await f.host.setSnapshot(try managedSnapshot("claude-idle")); f.controller.refresh(); try await f.settle()
        #expect(cards.card(id: id)?.status == .answered)
    }
}
