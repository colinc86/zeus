#if SA1_PROBE_HOST
import Foundation
import ZeusDesign
import ZeusProtocol
import ZeusSprites

@MainActor private final class SA1Routing: AgentRoutingSettings {
    var assistantSessionKey: String? { nil }
    var preferredAgent: AgentKind? { .claude }
    var deliveryMethod: DeliveryMethod = .tmux
    var tmuxTarget: String? { nil }
    var openCodeBaseURL: URL? { nil }
    var openCodeServerPassword: String? { nil }
    var managedSession: ManagedSessionConfig?
}
@MainActor private final class SA1Characters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []
    var currentCharacterID = "zeus"
}
@MainActor private final class SA1Context {
    var runtime: ZeusRuntime?
    var quiet = false
    var panel = true
    var previous: Data?
    let began = Date()
    let timeline: FileHandle
    init(root: URL) throws {
        let file = root.appendingPathComponent("timeline.jsonl")
        try Data().write(to: file); timeline = try FileHandle(forWritingTo: file)
    }
    func state(cards: CardStore, status: AvatarStatusModel) throws -> [String: JSONValue] {
        status.tick()
        guard let runtime else { return [:] }
        let row = ConversationActivityPresentation.make(runtime.assistantActivity, panelVisible: panel,
            managedStatus: runtime.managedStatus, managedSessionKey: runtime.managedController.sessionKey)
        return ["avatar": .string(status.state.rawValue), "detail": status.presentation.detail.map(JSONValue.string) ?? .null,
            "row": row.map { .string($0.label) } ?? .null, "phase": runtime.assistantActivity.map { .string(String(describing: $0.phase)) } ?? .null,
            "managed": .string(String(describing: runtime.managedStatus)), "panel": .bool(panel), "quiet": .bool(quiet),
            "can_input": .bool(runtime.managedController.canAcceptInput),
            "sample_t": runtime.managedController.latestInputSample.map { .number($0.capturedAt.timeIntervalSince(began)) } ?? .null,
            "pane": runtime.managedController.record?.pane.map { JSONValue.string($0.id) } ?? .null,
            "sessions": .number(Double(runtime.sessions.count)), "waiters": .number(Double(runtime.waiters.count)),
            "activity_deadline": runtime.assistantActivity.flatMap { runtime.activityRecords[$0.sessionKey] }.map { .number($0.deadline.timeIntervalSince(began)) } ?? .null,
            "cards": .array(cards.cards.map { card in
                ["id": .string(card.id), "title": .string(card.title ?? card.body), "status": .string(card.status.rawValue),
                 "seen": .bool(cards.seenIDs.contains(card.id)), "skipped": .bool(card.response?.skipped == true),
                 "options": .array(card.options.map { ["id": .string($0.id), "label": .string($0.label)] })]
            })]
    }
    func record(cards: CardStore, status: AvatarStatusModel, trigger: String? = nil) throws -> [String: JSONValue] {
        var state = try state(cards: cards, status: status)
        let encoder = ZeusJSON.encoder(); encoder.outputFormatting = [.sortedKeys]
        let core = try encoder.encode(JSONValue.object(state))
        if previous != core || trigger != nil {
            previous = core; state["t"] = .number(Date().timeIntervalSince(began))
            state["trigger"] = trigger.map(JSONValue.string) ?? .null
            var data = try encoder.encode(JSONValue.object(state)); data.append(10)
            try timeline.write(contentsOf: data)
        }
        state["t"] = .number(Date().timeIntervalSince(began))
        return state
    }
}

/// Headless, production presentation/runtime/controller. Only the explicitly passed private socket is used.
@main private struct SA1RuntimeHost {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5 else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), bridge = URL(fileURLWithPath: CommandLine.arguments[2])
        let claude = URL(fileURLWithPath: CommandLine.arguments[3]), tmux = URL(fileURLWithPath: CommandLine.arguments[4])
        let socket = root.appendingPathComponent("tmux.sock").path
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == root.appendingPathComponent("home").path else { throw CocoaError(.fileReadNoPermission) }
        let routing = SA1Routing(), context = try SA1Context(root: root)
        routing.managedSession = .init(enabled: true, folder: root.appendingPathComponent("home/project").path, agent: .claude,
            permissionModeID: "manual", launchPrompt: "SA1 private localhost fixture. Follow the supplied tool requests.", startWhenZeusOpens: true)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        cards.setConversationOpen(true)
        let status = AvatarStatusModel(cards: cards, quietHours: { [weak context] _ in context?.quiet == true },
            assistantActivity: { [weak context] in context?.runtime?.assistantActivity })
        cards.onAdd = { [weak status] in status?.noteNewCard($0) }
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: bridge, bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: .init(tmux: tmux, agents: [.claude: claude]),
            hosting: ManagedTmux(executable: tmux, environment: environment, testSocket: socket),
            environment: environment, isolatedSocket: socket)
        func makeRuntime() -> ZeusRuntime {
            ZeusRuntime(cards: cards, status: status, characters: SA1Characters(), routing: routing,
                socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
                quietHours: { [weak context] _ in context?.quiet == true }, managedController: controller)
        }
        context.runtime = makeRuntime(); try context.runtime?.start()
        let sampling = Task { @MainActor in
            while !Task.isCancelled {
                _ = try? context.record(cards: cards, status: status)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try write(["ready": true])
        await Task.detached {
            var line = Data()
            while let byte = try? FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 {
                    let data = line
                    await MainActor.run {
                        do {
                            let command = try ZeusJSON.decoder().decode(JSONValue.self, from: data)
                            Task { @MainActor in
                                do {
                                    guard let runtime = context.runtime else { throw CocoaError(.coderValueNotFound) }
                                    var response: [String: JSONValue] = ["ok": true]
                                    switch command["command"] {
                                    case "state": break
                                    case "snapshot":
                                        guard let pane = controller.record?.pane, let hosting = controller.hosting else { throw CocoaError(.coderValueNotFound) }
                                        let snapshot = try await hosting.capture(pane, owner: controller.record?.owner ?? "")
                                        response["classification"] = .string(String(describing: ManagedPaneClassifier.classify(snapshot, agent: .claude)))
                                        response["screen"] = .string(snapshot.plainLines.joined(separator: "\n"))
                                    case "send":
                                        guard case .string(let text) = command["text"] else { throw CocoaError(.coderValueNotFound) }
                                        response["result"] = .string(String(describing: await runtime.sendUserMessage(text, deliveryID: "d_sa1_" + UUID().uuidString)))
                                    case "panel":
                                        guard case .bool(let value) = command["open"] else { throw CocoaError(.coderValueNotFound) }
                                        context.panel = value; cards.setConversationOpen(value)
                                    case "quiet":
                                        guard case .bool(let value) = command["enabled"] else { throw CocoaError(.coderValueNotFound) }
                                        context.quiet = value
                                    case "answer", "skip":
                                        guard case .string(let id) = command["id"] else { throw CocoaError(.coderValueNotFound) }
                                        if command["command"] == "skip" { response["recorded"] = .bool(cards.skip(id: id)) }
                                        else {
                                            let option = command["option"]?.stringValue
                                            response["recorded"] = .bool(cards.respond(id: id, response: .init(optionID: option,
                                                optionLabel: cards.card(id: id)?.options.first { $0.id == option }?.label,
                                                text: command["text"]?.stringValue, device: .mac)))
                                        }
                                    case "own":
                                        runtime.stop(); routing.managedSession?.enabled = false
                                        context.runtime = makeRuntime(); try context.runtime?.start()
                                    default: throw CocoaError(.coderValueNotFound)
                                    }
                                    response["state"] = .object(try context.record(cards: cards, status: status,
                                        trigger: ["state", "snapshot"].contains(command["command"]?.stringValue ?? "") ? nil : command["command"]?.stringValue))
                                    try write(response)
                                } catch { try? write(["ok": false, "error": .string(error.localizedDescription)]) }
                            }
                        } catch { try? write(["ok": false, "error": .string(error.localizedDescription)]) }
                    }
                    line.removeAll(keepingCapacity: true)
                } else { line.append(byte) }
            }
        }.value
        sampling.cancel(); context.runtime?.stop(); try context.timeline.close()
    }
    private static func write(_ value: [String: JSONValue]) throws {
        var data = try ZeusJSON.encoder().encode(JSONValue.object(value)); data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
    }
}
private extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
}
#endif
