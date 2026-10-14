#if SA4_PROBE_HOST
import Foundation
import ZeusProtocol
import ZeusSprites

import Synchronization
@MainActor private struct SA4NoPassword: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
private final class SA4CaptureCounter: Sendable { let reads = Mutex(0) }
@MainActor private final class SA4Characters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []
    var currentCharacterID = "zeus"
}
private struct SA4Runner: ProcessRunning {
    let socket: String
    let environment: [String: String]
    var counter: SA4CaptureCounter? = nil
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let i = arguments.firstIndex(of: "-S"), arguments.indices.contains(i + 1), OwnSessionScreenReader.normalizedSocket(arguments[i + 1]) == OwnSessionScreenReader.normalizedSocket(socket),
              socket.contains("/zsa4_") else {
            try? FileHandle.standardError.write(contentsOf: Data("Rejected fixture namespace: \(arguments), expected \(socket)\n".utf8))
            throw ConnectorError.invalidURL
        }
        if arguments.contains("capture-pane") { counter?.reads.withLock { $0 += 1 } }
        do {
            let result = try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input, environment: environment)
            if result.status != 0 { try? FileHandle.standardError.write(contentsOf: Data("tmux \(arguments): \(String(decoding: result.stderr, as: UTF8.self))\n".utf8)) }
            return result
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("tmux \(arguments): \(error)\n".utf8)); throw error
        }
    }
}
@main private struct SA4RuntimeHost {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5, let agent = AgentKind(rawValue: CommandLine.arguments[3]),
              let backend = AssistantBackend(rawValue: agent.rawValue) else { throw ConnectorError.invalidURL }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let tmux = URL(fileURLWithPath: CommandLine.arguments[4]), environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == root.appendingPathComponent("home").path, root.path.contains("/zsa4_") else { throw ConnectorError.invalidURL }
        let socket = root.appendingPathComponent("bridge.sock").path
        let domain = "zeus.sa4." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: domain) else { throw ConnectorError.invalidURL }
        defer { defaults.removePersistentDomain(forName: domain) }
        let routing = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: SA4NoPassword())
        routing.managedSession = .init(enabled: false, folder: "", agent: agent, launchPrompt: "", startWhenZeusOpens: false)
        routing.backend = backend; routing.deliveryMethod = .tmux
        let counter = SA4CaptureCounter()
        let readRunner = SA4Runner(socket: root.appendingPathComponent("tmux.sock").path, environment: environment, counter: counter)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")); cards.setConversationOpen(true)
        var runtime: ZeusRuntime?
        let status = AvatarStatusModel(cards: cards, assistantActivity: { runtime?.assistantActivity })
        let live = ZeusRuntime(cards: cards, status: status, characters: SA4Characters(), routing: routing,
            socketPath: socket, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: SA4Runner(socket: root.appendingPathComponent("tmux.sock").path, environment: environment))],
            ownScreenReader: OwnSessionScreenReader(runner: readRunner, executable: { tmux }, environment: environment))
        runtime = live; try live.start(); defer { live.stop() }
        let began = Date(), timeline = root.appendingPathComponent("timeline.jsonl")
        try Data().write(to: timeline)
        let output = try FileHandle(forWritingTo: timeline); defer { try? output.close() }
        var previous: Data?
        func state() -> [String: JSONValue] {
            status.tick()
            return ["screen_reads": .number(Double(counter.reads.withLock { $0 })), "sampling": .bool(live.ownScreenTask != nil), "selected_pane": routing.tmuxTarget.map(JSONValue.string) ?? .null, "managed": .string(String(describing: live.managedStatus)), "avatar": .string(status.state.rawValue),
                "row": ConversationActivityPresentation.make(live.assistantActivity, panelVisible: true).map { .string($0.label) } ?? .null,
                "phase": live.assistantActivity.map { .string(String(describing: $0.phase)) } ?? .null,
                "activity_delivery": live.assistantActivity.flatMap { live.activityRecords[$0.sessionKey]?.deliveryID }.map(JSONValue.string) ?? .null,
                "sessions": .array(live.sessions.map { ["key": .string($0.sessionKey), "pane": $0.tmuxPane.map(JSONValue.string) ?? .null, "socket": $0.tmuxSocketPath.map(JSONValue.string) ?? .null] }),
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
                                if command["command"] == "send", case .string(let text) = command["text"], case .string(let id) = command["id"] {
                                    response["result"] = .string(String(describing: await live.sendUserMessage(text, deliveryID: id)))
                                } else if command["command"] == "classify", case .string(let screen) = command["screen"], case .string(let metadata) = command["metadata"] {
                                    response["classification"] = .string(String(describing: ManagedPaneClassifier.classify(.init(screen: screen, inputMetadata: metadata), agent: agent)))
                                } else if command["command"] == "select" {
                                    guard let session = live.sessions.first(where: { $0.agent == agent }) else { throw ManagedSessionError.invalidState }
                                    routing.assistantSessionKey = session.sessionKey
                                    let discovery = TmuxPaneDiscovery(executable: tmux, runner: SA4Runner(socket: root.appendingPathComponent("tmux.sock").path, environment: environment), environment: environment)
                                    await discovery.refresh(socketPath: session.tmuxSocketPath)
                                    guard let pane = discovery.panes.first(where: { $0.id == session.tmuxPane }) else { throw ManagedSessionError.command("Discovery: socket=\(session.tmuxSocketPath ?? "nil"), error=\(discovery.error ?? "nil"), guidance=\(discovery.guidance ?? "nil"), panes=\(discovery.panes)") }
                                    routing.setTmuxTarget(pane.id, socketPath: pane.socketPath)
                                    response["selected"] = .bool(routing.tmuxTarget == pane.id && routing.tmuxTargetSocketPath == AppSettings.normalizedTmuxSocket(session.tmuxSocketPath))
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
