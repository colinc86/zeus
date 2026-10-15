#if LM2_PROBE_HOST
import Foundation
import ZeusProtocol
import ZeusSprites

@MainActor private final class LM2Key: JournalKeyProviding {
    func key() throws -> Data { Data(repeating: 21, count: 32) }
}
@MainActor private final class LM2Cards: CardStoring, LearningNoticeRecording {
    var values: [Card] = [], notices: [LearningNotice] = []
    var responseHandler: ((Card, CardResponse) -> Void)?
    func add(_ card: Card) { values.append(card) }
    func card(id: String) -> Card? { values.first { $0.id == id } }
    func update(id: String, _ mutate: (inout Card) -> Void) -> Bool {
        guard let i = values.firstIndex(where: { $0.id == id }) else { return false }; mutate(&values[i]); return true
    }
    func dismiss(id: String) { _ = update(id: id) { $0.status = .dismissed } }
    func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?) -> Bool {
        guard !notices.contains(where: { $0.id == notice.id }) else { return false }; notices.append(notice); return true
    }
}
@MainActor private final class LM2Status: AvatarStatusControlling {
    func setOverride(_ state: AvatarState, detail: String?, progress: Double?, ttl: TimeInterval) {}
    func clearOverride() {}
    func setDeliveryProblem(_ message: String?) {}
}
@MainActor private final class LM2Characters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []; var currentCharacterID = "zeus"
}
@MainActor private final class LM2Routing: AgentRoutingSettings, TmuxTargetRouting {
    var assistantSessionKey: String?
    var preferredAgent: AgentKind? { .claude }
    var deliveryMethod: DeliveryMethod { .tmux }
    var tmuxTarget: String?
    var tmuxTargetSocketPath: String?
    var openCodeBaseURL: URL? { nil }
    var openCodeServerPassword: String? { nil }
}
@MainActor private final class LM2Clock: RuntimeClock {
    let now = ISO8601DateFormatter().date(from: "2026-10-14T18:15:00Z") ?? Date()
    func sleep(until date: Date) async throws { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSince(now)))) }
}
private struct LM2Runner: ProcessRunning {
    let socket: String
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let i = arguments.firstIndex(of: "-S"), arguments.indices.contains(i + 1),
              OwnSessionScreenReader.normalizedSocket(arguments[i + 1]) == OwnSessionScreenReader.normalizedSocket(socket) else { throw ConnectorError.invalidURL }
        return try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input)
    }
}
@main struct LM2Host {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), tmux = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.hasPrefix("/private/tmp/zlv1_") || root.path.hasPrefix("/tmp/zlv1_") else { throw ManagedSessionError.command("Refused fixture root: " + root.path) }
        let routing = LM2Routing(), cards = LM2Cards(), clock = LM2Clock()
        let socket = root.appendingPathComponent("tmux.sock").path
        let journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: LM2Key())
        let rules = try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: LM2Key())
        try journal.append(.init(id: "synthetic-editor", time: clock.now, level: .focus, app: "com.example.Editor", kind: .focus,
            payload: .init(.init(description: "Editing a synthetic test document; a test failed."))))
        var enabled = false
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let live = ZeusRuntime(cards: cards, status: LM2Status(), characters: LM2Characters(), routing: routing,
            clock: clock, socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: LM2Runner(socket: socket))],
            rules: rules, journal: journal, redactor: LocalRedactor(useOnDeviceModel: false),
            learningContext: { .init(frontmostApp: "com.example.Editor", idleSince: clock.now.addingTimeInterval(-601)) },
            reflectionEnabled: { enabled }, learningCalendar: calendar)
        try live.start(); defer { live.stop() }
        try write(["ready": true])
        await Task.detached {
            while let line = readLine() {
                await MainActor.run {
                    do {
                        let command = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                        if command["command"] == "reflect" {
                            guard let session = live.sessions.first else { throw ManagedSessionError.invalidState }
                            routing.assistantSessionKey = session.sessionKey; routing.tmuxTarget = session.tmuxPane; routing.tmuxTargetSocketPath = session.tmuxSocketPath
                            enabled = true; live.learningContextDidChange()
                        }
                        try write(["ok": true, "sessions": .number(Double(live.sessions.count)), "rules": .array(try rules.rules.map(JSONValue.from)),
                            "notices": .array(cards.notices.map { .string($0.summary) }),
                            "receipts": .array(try journal.items(matching: .init()).filter { $0.kind == .sentToAssistant }.map(JSONValue.from)),
                            "reflectionTexts": .array((live.ledger?.records ?? []).filter { $0.delivery.kind == .reflection }.map { .string($0.delivery.content) }),
                            "deliveries": .array((live.ledger?.records ?? []).map { ["kind": .string($0.delivery.kind.rawValue), "acked": .bool($0.delivery.ackedAt != nil), "attempts": .number(Double($0.delivery.attempts))] }),
                            "error": live.learningError.map(JSONValue.string) ?? .null])
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
