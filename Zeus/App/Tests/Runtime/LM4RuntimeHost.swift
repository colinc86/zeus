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
    private var offset = (ISO8601DateFormatter().date(from: "2026-10-14T18:15:00Z") ?? Date()).timeIntervalSinceNow
    var now: Date {
        get { Date().addingTimeInterval(offset) }
        set { offset = newValue.timeIntervalSinceNow }
    }
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
@MainActor private final class PA1Context { var value = LearningContext(); var levels: Set<JournalLevel> = [] }
@main struct LM4Host {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), tmux = URL(fileURLWithPath: CommandLine.arguments[2])
        let cli = URL(fileURLWithPath: CommandLine.arguments[3]), bridge = URL(fileURLWithPath: CommandLine.arguments[4])
        let env = ProcessInfo.processInfo.environment
        guard root.path.hasPrefix("/private/tmp/zlv1_") || root.path.hasPrefix("/tmp/zlv1_"), env["HOME"] == root.appendingPathComponent("home").path else { throw ManagedSessionError.invalidFolder }
        let routing = LM4Routing(), cards = LM4Cards(), learnings = LM4Learnings()
        let proactive = CommandLine.arguments.count > 5 && CommandLine.arguments[5].hasPrefix("pa1-")
        let proactiveClock = LM4Clock(), context = PA1Context()
        let defaultsName = "pa1-live-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: defaultsName) else { throw ManagedSessionError.invalidFolder }
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let briefSettings = MorningBriefSettings(defaults: defaults)
        if proactive { briefSettings.enabled = true; learnings.learningsEnabled = false }
        let rules = proactive ? try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: LM4Key()) : nil
        routing.managedSession = .init(enabled: true, folder: root.appendingPathComponent("project").path, agent: .claude, permissionModeID: "manual", launchPrompt: "Read Zeus learning deliveries as context and acknowledge their delivery_id.", startWhenZeusOpens: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let hosting = ManagedTmux(executable: tmux, runner: FoundationProcessRunner(), environment: env, testSocket: socket)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"), bridge: bridge, bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: .init(tmux: tmux, agents: [.claude: cli]), hosting: hosting, environment: env, isolatedSocket: socket, resourceDirectory: nil)
        let journal = EncryptedJournalStore(root: root.appendingPathComponent("Journal"), keyProvider: LM4Key())
        let ratings = try MessageRatingStore(fileURL: root.appendingPathComponent("ratings.zratings"), keyProvider: LM4Key())
        let folder = LearningFolderWriter(journal: journal, rules: nil, stateURL: root.appendingPathComponent("folder.json"),
            enabledLevels: { [.activity] }, redactor: LocalRedactor(useOnDeviceModel: false))
        let live = ZeusRuntime(cards: cards, status: LM4Status(), characters: LM4Characters(), routing: routing,
            clock: proactive ? proactiveClock : SystemRuntimeClock(), socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: LM4Runner(socket: socket))], managedController: controller,
            learnings: learnings, rules: rules, journal: journal, redactor: LocalRedactor(useOnDeviceModel: false), learningFolder: folder, messageRatings: ratings, learningContext: { context.value },
            morningBriefSettings: proactive ? briefSettings : nil, morningBriefLevels: { context.levels })
        try live.start(); defer { live.stop() }
        try write(["ready": true])
        await Task.detached {
            while let line = readLine() {
                await MainActor.run {
                    do {
                        let command = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                        if command["command"] == "rateFirst" {
                            if let first = cards.values.first(where: { $0.about == "On-call reminder" }) {
                                Task { @MainActor in
                                    do { _ = try await live.rate(cardID: first.id, rating: .down, scope: .kind, label: "On-call reminder") }
                                    catch { FileHandle.standardError.write(Data("Rating failed: \(error)\n".utf8)) }
                                }
                            }
                        }
                        if command["command"] == "brief" {
                            context.levels = [.focus]
                            let retained = Set(try journal.items(matching: .init()).map(\.id))
                            for index in 0..<6 where !retained.contains("brief-evidence-\(index)") {
                                try journal.append(.init(id: "brief-evidence-\(index)", time: proactiveClock.now.addingTimeInterval(-86400 + Double(index)), level: .focus, kind: .focus,
                                    payload: .init(.init(description: "Synthetic project \(index): " + String(repeating: "reviewed project notes and prepared a draft for tomorrow; ", count: 6)))))
                            }
                            live.noteProactiveActivity(at: proactiveClock.now)
                        }
                        if command["command"] == "nextBrief" { context.levels = []; proactiveClock.now = proactiveClock.now.addingTimeInterval(86400); live.noteProactiveActivity(at: proactiveClock.now) }
                        if command["command"] == "triggers", let rules {
                            let active = try rules.propose([.init(sentence: "Prepare the synthetic project recap", trigger: .init(state: "fixture ready"), kind: .acts)], at: proactiveClock.now)[0]
                            _ = try rules.markShadowShown(id: active.id)
                            try rules.setStatus(.active, id: active.id, at: proactiveClock.now)
                            _ = try rules.propose([.init(sentence: "Draft the synthetic project checklist", trigger: .init(state: "fixture ready"), kind: .acts)], at: proactiveClock.now)
                            context.value.states = ["fixture ready"]; live.learningContextDidChange()
                        }
                        if command["command"] == "digest" { learnings.digest() }
                        if command["command"] == "eraseThenLateAck" {
                            try journal.delete(.all)
                            _ = try live.acknowledge(ids: ["lm4-digest"], sessionKey: controller.sessionKey ?? "")
                            live.recordReflectionReceipt(id: "lm4-digest")
                        }
                        try write(["ok": true, "status": .string(String(describing: live.managedStatus)), "sessions": .number(Double(live.sessions.count)),
                            "pane": controller.record?.pane.map { .string($0.id) } ?? .null,
                            "cards": .array(try cards.values.map(JSONValue.from)),
                            "ruleActions": .array(try (rules?.ruleActions ?? []).map(JSONValue.from)),
                            "ratings": .number(Double(live.ratings.count)),
                            "muted": .array(live.mutedToday.map(JSONValue.string)),
                            "unread": .number(Double(learnings.values.count)),
                            "receipts": .array(try journal.items(matching: .init()).filter { $0.kind == .sentToAssistant }.map(JSONValue.from)),
                            "deliveries": .array((live.ledger?.records ?? []).map { ["id": .string($0.delivery.id), "kind": .string($0.delivery.kind.rawValue), "content": .string($0.delivery.content), "meta": .object($0.delivery.meta.mapValues(JSONValue.string)), "acked": .bool($0.delivery.ackedAt != nil), "attempts": .number(Double($0.delivery.attempts)), "discarded": .bool($0.discardedAt != nil)] }),
                            "error": live.learningError.map(JSONValue.string) ?? .null])
                    } catch { try? write(["ok": false, "error": .string(String(describing: error))]) }
                }
            }
        }.value
    }
    private static func write(_ value: JSONValue) throws { var data = try JSONEncoder().encode(value); data.append(10); try FileHandle.standardOutput.write(contentsOf: data) }
}
#endif
