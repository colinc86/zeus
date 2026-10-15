#if LM4_PROBE_HOST
import Foundation
import ZeusProtocol
import ZeusSprites

@MainActor private final class LM4Key: FixtureLearningKeyProviding {
    func key() throws -> Data { Data(repeating: 21, count: 32) }
}
@MainActor private final class LM4Cards: CardStoring, LearningNoticeRecording {
    var values: [Card] = [], notices: [LearningNotice] = []
    var actions: [String: @MainActor () -> Void] = [:]
    var responseHandler: ((Card, CardResponse) -> Void)?
    func add(_ card: Card) { values.append(card) }
    func card(id: String) -> Card? { values.first { $0.id == id } }
    func update(id: String, _ mutate: (inout Card) -> Void) -> Bool {
        guard let i = values.firstIndex(where: { $0.id == id }) else { return false }; mutate(&values[i]); return true
    }
    func dismiss(id: String) { _ = update(id: id) { $0.status = .dismissed } }
    func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?) -> Bool {
        actions[notice.id] = action
        if let index = notices.firstIndex(where: { $0.id == notice.id }) { notices[index] = notice; return false }
        notices.append(notice); return true
    }
}
@MainActor private final class LM4Status: AvatarStatusControlling {
    func setOverride(_ state: AvatarState, detail: String?, progress: Double?, ttl: TimeInterval) {}
    func clearOverride() {}
    func setDeliveryProblem(_ message: String?) {}
}
@MainActor private final class LM4Characters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []; var currentCharacterID = "zeus"
}
@MainActor private final class LM4Routing: AgentRoutingSettings, TmuxTargetRouting {
    var managedSession: ManagedSessionConfig?
    var assistantSessionKey: String?
    var preferredAgent: AgentKind? { .claude }
    var deliveryMethod: DeliveryMethod { .tmux }
    var tmuxTarget: String?
    var tmuxTargetSocketPath: String?
    var openCodeBaseURL: URL? { nil }
    var openCodeServerPassword: String? { nil }
}
@MainActor private final class LM4Clock: RuntimeClock {
    let now = ISO8601DateFormatter().date(from: "2026-10-14T18:15:00Z") ?? Date()
    func sleep(until date: Date) async throws { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSince(now)))) }
}
private struct LM4Runner: ProcessRunning {
    let socket: String
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let i = arguments.firstIndex(of: "-S"), arguments.indices.contains(i + 1),
              OwnSessionScreenReader.normalizedSocket(arguments[i + 1]) == OwnSessionScreenReader.normalizedSocket(socket) else { throw ConnectorError.invalidURL }
        return try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input)
    }
}
@MainActor private final class LM4Learnings: LearningsProviding {
    var learningsEnabled = true
    var values: [Learning] = []
    var onNewLearning: ((Learning) -> Void)?
    func unreadLearnings() -> [Learning] { values }
    func markLearningsRead(through id: String) { if let i = values.firstIndex(where: { $0.id == id }) { values.removeFirst(i + 1) } }
    func digest() { let value = Learning(id: "lm4-digest", kind: .digest, createdAt: Date(), text: "Synthetic morning summary: working on a fixture project."); values.append(value); onNewLearning?(value) }
}
@main struct LM4Host {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), tmux = URL(fileURLWithPath: CommandLine.arguments[2])
        let cli = URL(fileURLWithPath: CommandLine.arguments[3]), bridge = URL(fileURLWithPath: CommandLine.arguments[4])
        let env = ProcessInfo.processInfo.environment
        guard root.path.hasPrefix("/private/tmp/zlv1_") || root.path.hasPrefix("/tmp/zlv1_"), env["HOME"] == root.appendingPathComponent("home").path else { throw ManagedSessionError.invalidFolder }
        let routing = LM4Routing(), cards = LM4Cards(), learnings = LM4Learnings()
        routing.managedSession = .init(enabled: true, folder: root.appendingPathComponent("project").path, agent: .claude, permissionModeID: "manual", launchPrompt: "Read Zeus learning deliveries as context and acknowledge their delivery_id.", startWhenZeusOpens: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let hosting = ManagedTmux(executable: tmux, runner: FoundationProcessRunner(), environment: env, testSocket: socket)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"), bridge: bridge, bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: .init(tmux: tmux, agents: [.claude: cli]), hosting: hosting, environment: env, isolatedSocket: socket, resourceDirectory: nil)
        let journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: LM4Key())
        let live = ZeusRuntime(cards: cards, status: LM4Status(), characters: LM4Characters(), routing: routing,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: LM4Runner(socket: socket))], managedController: controller,
            learnings: learnings, journal: journal, redactor: LocalRedactor(useOnDeviceModel: false))
        try live.start(); defer { live.stop() }
        try write(["ready": true])
        await Task.detached {
            while let line = readLine() {
                await MainActor.run {
                    do {
                        let command = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                        if command["command"] == "digest" { learnings.digest() }
                        if command["command"] == "eraseThenLateAck" {
                            try journal.delete(.all)
                            _ = try live.acknowledge(ids: ["lm4-digest"], sessionKey: controller.sessionKey ?? "")
                            live.recordReflectionReceipt(id: "lm4-digest")
                        }
                        try write(["ok": true, "status": .string(String(describing: live.managedStatus)), "sessions": .number(Double(live.sessions.count)),
                            "pane": controller.record?.pane.map { .string($0.id) } ?? .null,
                            "unread": .number(Double(learnings.values.count)),
                            "receipts": .array(try journal.items(matching: .init()).filter { $0.kind == .sentToAssistant }.map(JSONValue.from)),
                            "deliveries": .array((live.ledger?.records ?? []).map { ["id": .string($0.delivery.id), "kind": .string($0.delivery.kind.rawValue), "acked": .bool($0.delivery.ackedAt != nil), "attempts": .number(Double($0.delivery.attempts)), "discarded": .bool($0.discardedAt != nil)] }),
                            "error": live.learningError.map(JSONValue.string) ?? .null])
                    } catch { try? write(["ok": false, "error": .string(String(describing: error))]) }
                }
            }
        }.value
    }
    private static func write(_ value: JSONValue) throws { var data = try JSONEncoder().encode(value); data.append(10); try FileHandle.standardOutput.write(contentsOf: data) }
}
#endif
