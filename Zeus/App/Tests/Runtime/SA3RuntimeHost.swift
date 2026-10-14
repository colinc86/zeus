#if SA3_PROBE_HOST
import Foundation
import ZeusProtocol
import ZeusSprites

// SetupCommands is compiled unchanged, with its app-owned backend enum supplied
// here so this headless fixture doesn't import the actual Settings/preferences.
enum AssistantBackend: String, CaseIterable {
    case claude, codex, opencode
    var name: String { rawValue }
}
@MainActor private final class SA3Routing: AgentRoutingSettings {
    var assistantSessionKey: String? { nil }
    var deliveryMethod: DeliveryMethod { .tmux }
    var tmuxTarget: String? { nil }
    var openCodeBaseURL: URL? { nil }
}
@MainActor private final class SA3Characters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []
    var currentCharacterID = "zeus"
}
private struct SA3Runner: ProcessRunning {
    let socket: String
    let environment: [String: String]
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let i = arguments.firstIndex(of: "-S"), arguments.indices.contains(i + 1), arguments[i + 1] == socket,
              socket.contains("/zsa3_") else { throw ConnectorError.invalidURL }
        return try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input, environment: environment)
    }
}
@main private struct SA3RuntimeHost {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5, let agent = AgentKind(rawValue: CommandLine.arguments[3]),
              let backend = AssistantBackend(rawValue: agent.rawValue) else { throw ConnectorError.invalidURL }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), bridge = CommandLine.arguments[2]
        let tmux = URL(fileURLWithPath: CommandLine.arguments[4]), environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == root.appendingPathComponent("home").path, root.path.contains("/zsa3_") else { throw ConnectorError.invalidURL }
        let socket = root.appendingPathComponent("bridge.sock").path
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")); cards.setConversationOpen(true)
        var runtime: ZeusRuntime?
        let status = AvatarStatusModel(cards: cards, assistantActivity: { runtime?.assistantActivity })
        let live = ZeusRuntime(cards: cards, status: status, characters: SA3Characters(), routing: SA3Routing(),
            socketPath: socket, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: SA3Runner(socket: root.appendingPathComponent("tmux.sock").path, environment: environment))])
        runtime = live; try live.start(); defer { live.stop() }
        let began = Date(), timeline = root.appendingPathComponent("timeline.jsonl")
        try Data().write(to: timeline)
        let output = try FileHandle(forWritingTo: timeline); defer { try? output.close() }
        var previous: Data?
        func state() -> [String: JSONValue] {
            status.tick()
            return ["managed": .string(String(describing: live.managedStatus)), "avatar": .string(status.state.rawValue),
                "row": ConversationActivityPresentation.make(live.assistantActivity, panelVisible: true).map { .string($0.label) } ?? .null,
                "phase": live.assistantActivity.map { .string(String(describing: $0.phase)) } ?? .null,
                "activity_delivery": live.assistantActivity.flatMap { live.activityRecords[$0.sessionKey]?.deliveryID }.map(JSONValue.string) ?? .null,
                "sessions": .array(live.sessions.map { ["key": .string($0.sessionKey), "pane": $0.tmuxPane.map(JSONValue.string) ?? .null] }),
                "cards": .array(cards.cards.map { ["body": .string($0.body), "id": .string($0.id)] }),
                "deliveries": .array((live.ledger?.records ?? []).map { ["id": .string($0.delivery.id), "acked": .bool($0.delivery.ackedAt != nil), "attempts": .number(Double($0.delivery.attempts))] })]
        }
        let sampling = Task { @MainActor in
            while !Task.isCancelled {
                var value = state()
                if let data = try? ZeusJSON.encoder().encode(JSONValue.object(value)), data != previous {
                    previous = data; value["t"] = .number(Date().timeIntervalSince(began))
                    if var data = try? ZeusJSON.encoder().encode(JSONValue.object(value)) { data.append(10); try? output.write(contentsOf: data) }
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        defer { sampling.cancel() }
        try write(["ready": true, "launch": .string(SetupCommands.steps(for: backend, bridgePath: bridge, socketPath: socket)[1].command ?? ""),
                   "configuration": .string(SetupCommands.configuration(for: backend, bridgePath: bridge))])
        await Task.detached {
            var line = Data()
            while let byte = try? FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 {
                    let data = line
                    _ = await MainActor.run {
                        Task { @MainActor in
                            do {
                                let command = try ZeusJSON.decoder().decode(JSONValue.self, from: data)
                                var response: [String: JSONValue] = ["ok": true]
                                if command["command"] == "send", case .string(let text) = command["text"], case .string(let id) = command["id"] {
                                    response["result"] = .string(String(describing: await live.sendUserMessage(text, deliveryID: id)))
                                } else if command["command"] != "state" { throw ManagedSessionError.invalidState }
                                var value = state(); value["t"] = .number(Date().timeIntervalSince(began)); response["state"] = .object(value)
                                try write(response)
                            } catch { try? write(["ok": false, "error": .string(error.localizedDescription)]) }
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                } else { line.append(byte) }
            }
        }.value
    }
    private static func write(_ value: [String: JSONValue]) throws {
        var data = try ZeusJSON.encoder().encode(JSONValue.object(value)); data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
    }
}
#endif
