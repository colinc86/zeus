#if SA2_PROBE_HOST
import Foundation
import ZeusProtocol
import ZeusSprites

@MainActor private final class SA2Routing: AgentRoutingSettings {
    var assistantSessionKey: String? { nil }
    var deliveryMethod: DeliveryMethod = .tmux
    var tmuxTarget: String? { nil }
    var openCodeBaseURL: URL? { nil }
    var managedSession: ManagedSessionConfig?
}
@MainActor private final class SA2Characters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []
    var currentCharacterID = "zeus"
}

/// Changes only the model endpoint on the actual managed launch. Every process
/// command is restricted to this host's private socket and disposable profiles.
private struct SA2Runner: ProcessRunning {
    let socket: String
    let base: URL
    let environment: [String: String]
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input, environment: environment)
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        guard let index = arguments.firstIndex(of: "-S"), arguments.indices.contains(index + 1),
              arguments[index + 1] == socket, socket.contains("/zsa2_"), base.host == "127.0.0.1" else { throw ConnectorError.invalidURL }
        var args = arguments
        if args.contains("respawn-pane") {
            if args.contains("--no-daemon") {
                let project = URL(fileURLWithPath: environment["HOME"] ?? "").deletingLastPathComponent().appendingPathComponent("project").path
                let overrides = ["check_for_update_on_startup=false", "model=\"sa2\"", "model_provider=\"sa2\"",
                    "model_providers.sa2={name=\"SA2 localhost fixture\",base_url=\"\(base.absoluteString)/v1\",wire_api=\"responses\",requires_openai_auth=false}",
                    "projects.\"\(project)\".trust_level=\"trusted\""]
                args.insert(contentsOf: overrides.flatMap { ["-c", $0] }, at: args.count - 1)
            } else if let configIndex = args.firstIndex(where: { $0.hasPrefix("OPENCODE_CONFIG_CONTENT=") }) {
                let raw = String(args[configIndex].dropFirst("OPENCODE_CONFIG_CONTENT=".count))
                guard var config = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw ConnectorError.invalidURL }
                config["autoupdate"] = false; config["share"] = "disabled"
                config["model"] = "openai/gpt-4.1-mini"; config["enabled_providers"] = ["openai"]
                config["provider"] = ["openai": ["options": ["baseURL": base.absoluteString + "/v1", "apiKey": "sa2-local-fixture"]]]
                args[configIndex] = "OPENCODE_CONFIG_CONTENT=" + String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
            }
            let extras = ["XDG_CACHE_HOME", "XDG_STATE_HOME", "OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_EXTERNAL_PLUGINS", "OPENCODE_DISABLE_MODELS_FETCH", "OPENCODE_DISABLE_LSP_DOWNLOAD"]
                .compactMap { key in environment[key].map { key + "=" + $0 } }
            if let index = args.firstIndex(of: "/usr/bin/env") { args.insert(contentsOf: extras, at: index + 1) }
        }
        return try await FoundationProcessRunner().run(executable: executable, arguments: args, input: input, environment: environment)
    }
}

/// Real-clock headless app presentation, runtime, managed controller and bridge.
/// Compiled separately under build/; it never starts during the normal test suite.
@main private struct SA2RuntimeHost {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 7, let agent = AgentKind(rawValue: CommandLine.arguments[3]), [.codex, .opencode].contains(agent),
              let base = URL(string: CommandLine.arguments[6]), base.host == "127.0.0.1" else { throw ConnectorError.invalidURL }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), bridge = URL(fileURLWithPath: CommandLine.arguments[2])
        let cli = URL(fileURLWithPath: CommandLine.arguments[4]), tmux = URL(fileURLWithPath: CommandLine.arguments[5])
        let socket = root.appendingPathComponent("tmux.sock").path, env = ProcessInfo.processInfo.environment
        guard env["HOME"] == root.appendingPathComponent("home").path else { throw ConnectorError.invalidURL }
        let routing = SA2Routing()
        routing.managedSession = .init(enabled: true, folder: root.appendingPathComponent("project").path, agent: agent,
            permissionModeID: agent == .opencode ? "allow" : "workspace-write/on-request", launchPrompt: "SA2 isolated localhost state accuracy fixture.", startWhenZeusOpens: true)
        let runner = SA2Runner(socket: socket, base: base, environment: env)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: bridge, bridgeSocket: root.appendingPathComponent("bridge.sock").path, executables: .init(tmux: tmux, agents: [agent: cli]),
            hosting: ManagedTmux(executable: tmux, runner: runner, environment: env, testSocket: socket), environment: env, isolatedSocket: socket)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")); cards.setConversationOpen(true)
        var runtime: ZeusRuntime?
        let status = AvatarStatusModel(cards: cards, assistantActivity: { runtime?.assistantActivity })
        cards.onAdd = { [weak status] in status?.noteNewCard($0) }
        let live = ZeusRuntime(cards: cards, status: status, characters: SA2Characters(), routing: routing,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: runner)], managedController: controller)
        runtime = live; try live.start(); defer { live.stop() }
        let began = Date(), timeline = root.appendingPathComponent("timeline.jsonl")
        try Data().write(to: timeline)
        let output = try FileHandle(forWritingTo: timeline); defer { try? output.close() }
        var previous: Data?
        func state() throws -> [String: JSONValue] {
            status.tick()
            let row = ConversationActivityPresentation.make(live.assistantActivity, panelVisible: true, managedStatus: live.managedStatus, managedSessionKey: controller.sessionKey)
            return ["managed": .string(String(describing: live.managedStatus)), "avatar": .string(status.state.rawValue), "row": row.map { .string($0.label) } ?? .null,
                "phase": live.assistantActivity.map { .string(String(describing: $0.phase)) } ?? .null,
                "activity_delivery": live.assistantActivity.flatMap { live.activityRecords[$0.sessionKey]?.deliveryID }.map(JSONValue.string) ?? .null,
                "sample_t": controller.latestInputSample.map { .number($0.capturedAt.timeIntervalSince(began)) } ?? .null,
                "draft": controller.latestInputSample?.draftText.map(JSONValue.string) ?? .null, "sessions": .number(Double(live.sessions.count)),
                "pane": controller.record?.pane.map { .string($0.id) } ?? .null,
                "cards": .array(cards.cards.map { ["body": .string($0.body), "id": .string($0.id)] }),
                "deliveries": .array((live.ledger?.records ?? []).map { ["id": .string($0.delivery.id), "acked": .bool($0.delivery.ackedAt != nil), "attempts": .number(Double($0.delivery.attempts))] })]
        }
        let sampling = Task { @MainActor in
            while !Task.isCancelled {
                if var value = try? state(), let encoded = try? ZeusJSON.encoder().encode(JSONValue.object(value)), previous != encoded {
                    previous = encoded; value["t"] = .number(Date().timeIntervalSince(began))
                    if var data = try? ZeusJSON.encoder().encode(JSONValue.object(value)) { data.append(10); try? output.write(contentsOf: data) }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { sampling.cancel() }
        try write(["ready": true])
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
                                switch command["command"] {
                                case "state": break
                                case "snapshot":
                                    guard let pane = controller.record?.pane, let hosting = controller.hosting else { throw ManagedSessionError.invalidState }
                                    let frame = try await hosting.capture(pane, owner: controller.record?.owner ?? "")
                                    response["snapshot"] = ["screen": .string(frame.screen), "inputMetadata": .string(frame.inputMetadata),
                                        "classification": .string(String(describing: ManagedPaneClassifier.classify(frame, agent: agent)))]
                                case "send":
                                    guard case .string(let text) = command["text"], case .string(let id) = command["id"] else { throw ManagedSessionError.invalidState }
                                    response["result"] = .string(String(describing: await live.sendUserMessage(text, deliveryID: id)))
                                case "stop": controller.stopManagedSession()
                                default: throw ManagedSessionError.invalidState
                                }
                                var value = try state(); value["t"] = .number(Date().timeIntervalSince(began)); response["state"] = .object(value)
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
