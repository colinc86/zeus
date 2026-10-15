import Foundation
import Observation
import Testing
import ZeusLink
import ZeusProtocol
import ZeusSprites
@testable import Zeus

@MainActor
final class TestRuntimeClock: RuntimeClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    private var sleeps: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleeps[id] = (deadline, continuation)
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { sleeps.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    var pendingDeadlines: [Date] { sleeps.values.map { $0.0 } }
    func advance(_ seconds: TimeInterval, wake: Bool = true) {
        now = now.addingTimeInterval(seconds)
        if wake {
            for (id, value) in sleeps where value.0 <= now {
                sleeps.removeValue(forKey: id)?.1.resume()
            }
        }
    }
}

@MainActor
final class FakeCards: CardStoring, LocalCardActionHandling, AppChangeRecording, LearningNoticeRecording {
    var learningNotices: [LearningNotice] = []
    var learningActions: [String: @MainActor () -> Void] = [:]
    func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?) -> Bool {
        learningActions[notice.id] = action
        if let i = learningNotices.firstIndex(where: { $0.id == notice.id }) { learningNotices[i] = notice; return false }
        learningNotices.append(notice); return true
    }
    let clock: TestRuntimeClock
    var values: [Card] = []
    var responseHandler: ((Card, CardResponse) -> Void)?
    var localActionHandler: ((Card, CardResponse) -> Bool)?
    var onAdd: ((Card) -> Void)?
    var appChanges: [AppChange] = []
    func recordAppChange(_ change: AppChange) { appChanges.append(change) }
    init(clock: TestRuntimeClock) { self.clock = clock }
    func add(_ card: Card) { values.append(card); onAdd?(card) }
    func card(id: String) -> Card? { values.first { $0.id == id } }
    func update(id: String, _ mutate: (inout Card) -> Void) -> Bool {
        guard let index = values.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&values[index]); values[index].updatedAt = clock.now; return true
    }
    func dismiss(id: String) { _ = update(id: id) { $0.status = .dismissed } }
    func respond(id: String, option: String? = nil, label: String? = nil, text: String? = nil, device: CardResponse.Device = .mac) {
        guard let index = values.firstIndex(where: { $0.id == id }), values[index].status == .open else { return }
        let answer = CardResponse(optionID: option, optionLabel: label, text: text, respondedAt: clock.now, device: device)
        if localActionHandler?(values[index], answer) == true { return }
        values[index].response = answer; values[index].status = .answered
        responseHandler?(values[index], answer)
    }
}

@MainActor
final class FakeStatus: AvatarStatusControlling {
    var state: AvatarState?
    var detail: String?
    var progress: Double?
    var ttl: TimeInterval?
    var problem: String?
    var quiet = false
    func setOverride(_ state: AvatarState, detail: String?, progress: Double?, ttl: TimeInterval) {
        self.state = state; self.detail = detail; self.progress = progress; self.ttl = ttl
    }
    func clearOverride() { state = nil }
    func setDeliveryProblem(_ message: String?) { problem = message }
}

@MainActor
final class FakeCharacters: CharacterControlling {
    var availableCharacters = CharacterLibrary.load(userDirectory: nil).characters
    var currentCharacterID = "zeus"
}

@MainActor
@Observable
final class FakeRouting: AgentRoutingSettings, OpenCodeSessionRouting, OpenCodeDestinationRouting, TmuxTargetRouting {
    var assistantSessionKey: String?
    var managedSession: ManagedSessionConfig?
    var preferredAgent: AgentKind?
    var openCodeServerPassword: String?
    var deliveryMethod: DeliveryMethod = .channel
    var tmuxTarget: String?
    var tmuxTargetSocketPath: String? = "/test/tmux.sock"
    var openCodeBaseURL: URL?
    var openCodeDestinations: [String: OpenCodeDestination] = [:]
    var openCodeSessionIDs: [String: String] = [:] {
        didSet {
            openCodeDestinations = openCodeDestinations.filter { openCodeSessionIDs[$0.key] == $0.value.sessionID }
            for (key, id) in openCodeSessionIDs where oldValue[key] != id {
                openCodeDestinations[key] = openCodeBaseURL.flatMap { OpenCodeDestination(sessionID: id, endpoint: $0) }
            }
        }
    }
    func openCodeDestination(for sessionKey: String) -> OpenCodeDestination? { openCodeDestinations[sessionKey] }
    func openCodeSessionID(for sessionKey: String) -> String? { openCodeSessionIDs[sessionKey] }
}

@MainActor
final class FakeConnector: DeliveryConnector {
    var available = true
    var fails = false
    var deliveries: [Delivery] = []
    var onSend: ((Delivery) -> Void)?
    var hold = false
    var waits: [CheckedContinuation<Void, any Error>] = []
    func canDeliver(to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) -> Bool { available }
    func deliver(_ delivery: Delivery, to session: ConnectedSession, bridge: BridgeSession?, routing: any AgentRoutingSettings) async throws {
        deliveries.append(delivery); onSend?(delivery)
        if hold { try await withCheckedThrowingContinuation { waits.append($0) } }
        try Task.checkCancellation()
        if fails { throw BridgeLinkError.disconnected }
    }
    func release() { let current = waits; waits.removeAll(); for waiter in current { waiter.resume() } }
}

@MainActor
struct RuntimeFixture {
    let directory: URL
    let clock: TestRuntimeClock
    let cards: FakeCards
    let status: FakeStatus
    let characters: FakeCharacters
    let routing: FakeRouting
    let connector: FakeConnector
    let runtime: ZeusRuntime
    init(channelOnly: Bool = false, directory: URL? = nil, appControl: (any AppControlling)? = nil, learnings: (any LearningsProviding)? = nil, ownScreenReader: (any OwnSessionScreenReading)? = nil) throws {
        self.directory = directory ?? URL(fileURLWithPath: "/tmp/zrun_" + UUID().uuidString.prefix(8))
        clock = TestRuntimeClock(); cards = FakeCards(clock: clock); status = FakeStatus()
        characters = FakeCharacters(); routing = FakeRouting(); connector = FakeConnector()
        runtime = ZeusRuntime(cards: cards, status: status, characters: characters, routing: routing, clock: clock,
                              socketPath: self.directory.appendingPathComponent("bridge.sock").path,
                              ledgerURL: self.directory.appendingPathComponent("deliveries.json"),
                              connectors: channelOnly ? [ChannelDeliveryConnector()] : [connector], quietHours: { [status] _ in status.quiet }, targetIsDead: { _ in false }, appControl: appControl, learnings: learnings, ownScreenReader: ownScreenReader ?? OwnSessionScreenReader())
        try runtime.start()
    }
    func connect(_ key: String = "claude:/assistant", channel: Bool = true, agent: AgentKind = .claude, id: UUID = UUID()) {
        runtime.registerSession(.init(id: id, sessionKey: key, agent: agent, cwd: "/assistant", clientName: "Fake",
                                      supportsChannel: channel, tmuxPane: nil, connectedAt: clock.now))
    }
    func stop(remove: Bool = true) {
        connector.release(); runtime.stop()
        if remove { try? FileManager.default.removeItem(at: directory) }
    }
    func call(_ name: String, _ args: JSONValue = [:], session: String = "claude:/assistant") async -> ToolResult {
        await runtime.callTool(name, arguments: args, sessionKey: session)
    }
}

enum RuntimeTestError: Error { case deadline }
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < end else { throw RuntimeTestError.deadline }
        try await Task.sleep(for: .milliseconds(5))
    }
}
