#if ST1_PROBE_HOST
import Foundation
import ZeusProtocol
import ZeusSprites

// ST1 live probe host: the production runtime with "Only my assistant" on, Auto, and a private tmux. Two real
// Claude sessions connect through the real bridge; the Python driver asks for state and picks sessions.

@MainActor private final class ST1Cards: CardStoring, AdmissionNoticeRecording {
    var values: [Card] = []
    var notices: [AdmissionNotice] = []
    var responseHandler: ((Card, CardResponse) -> Void)?
    func add(_ card: Card) { values.append(card) }
    func card(id: String) -> Card? { values.first { $0.id == id } }
    func update(id: String, _ mutate: (inout Card) -> Void) -> Bool {
        guard let i = values.firstIndex(where: { $0.id == id }) else { return false }; mutate(&values[i]); return true
    }
    func dismiss(id: String) { _ = update(id: id) { $0.status = .dismissed } }
    func recordAdmissionNotice(_ notice: AdmissionNotice) -> Bool {
        if let i = notices.firstIndex(where: { $0.id == notice.id }) { notices[i] = notice; return false }
        notices.append(notice); return true
    }
}
@MainActor private final class ST1Status: AvatarStatusControlling {
    func setOverride(_ state: AvatarState, detail: String?, progress: Double?, ttl: TimeInterval) {}
    func clearOverride() {}
    func setDeliveryProblem(_ message: String?) {}
}
@MainActor private final class ST1Characters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []; var currentCharacterID = "zeus"
}
@MainActor private final class ST1Routing: AgentRoutingSettings, TmuxTargetRouting, AssistantAdmissionRouting {
    var assistantSessionKey: String? { didSet { if assistantSessionKey != nil { adoptedAssistantSessionKey = nil } } }
    var onlyAssistantMayTalk = true
    var adoptedAssistantSessionKey: String?
    func makeAssistant(_ sessionKey: String) { assistantSessionKey = sessionKey }
    var preferredAgent: AgentKind? { .claude }
    var deliveryMethod: DeliveryMethod { .tmux }
    var tmuxTarget: String?
    var tmuxTargetSocketPath: String?
    var openCodeBaseURL: URL? { nil }
    var openCodeServerPassword: String? { nil }
}
@MainActor private final class ST1Clock: RuntimeClock {
    var now: Date { Date() }
    func sleep(until date: Date) async throws { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
}
private struct ST1Runner: ProcessRunning {
    let socket: String
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let i = arguments.firstIndex(of: "-S"), arguments.indices.contains(i + 1),
              OwnSessionScreenReader.normalizedSocket(arguments[i + 1]) == OwnSessionScreenReader.normalizedSocket(socket) else { throw ConnectorError.invalidURL }
        return try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input)
    }
}
@main struct ST1Host {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), tmux = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.hasPrefix("/private/tmp/zlv1_") || root.path.hasPrefix("/tmp/zlv1_") else { throw ManagedSessionError.command("Refused fixture root: " + root.path) }
        let routing = ST1Routing(), cards = ST1Cards(), clock = ST1Clock()
        let socket = root.appendingPathComponent("tmux.sock").path
        let live = ZeusRuntime(cards: cards, status: ST1Status(), characters: ST1Characters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: ST1Runner(socket: socket))])
        try live.start(); defer { live.stop() }
        try write(["ready": true])
        await Task.detached {
            while let line = readLine() {
                await MainActor.run {
                    do {
                        let command = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                        if command["command"] == "pick", case .string(let key)? = command["key"] { routing.makeAssistant(key) }
                        if command["command"] == "primary", case .string(let id)? = command["id"] {
                            guard let notice = cards.notices.first(where: { $0.id == id }) else { throw ManagedSessionError.invalidState }
                            notice.primary.run()
                        }
                        try write(["ok": true,
                            "sessions": .array(live.sessions.map { ["key": .string($0.sessionKey), "cwd": .string($0.cwd), "channel": .bool($0.supportsChannel)] }),
                            "adopted": routing.adoptedAssistantSessionKey.map(JSONValue.string) ?? .null,
                            "picked": routing.assistantSessionKey.map(JSONValue.string) ?? .null,
                            "assistantTarget": live.assistantTarget.map(JSONValue.string) ?? .null,
                            "cards": .array(cards.values.map { ["body": .string($0.body), "session": .string($0.sessionKey ?? "")] }),
                            "notices": .array(cards.notices.map { ["id": .string($0.id), "summary": .string($0.summary), "primary": .string($0.primary.title),
                                "primaryDone": $0.primary.doneTitle.map(JSONValue.string) ?? .null, "secondary": $0.secondary.map { .string($0.title) } ?? .null] })])
                    } catch { try? write(["ok": false, "error": .string(String(describing: error))]) }
                }
            }
        }.value
    }
    private static func write(_ value: JSONValue) throws {
        var data = try JSONEncoder().encode(value); data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
    }
}
#endif
