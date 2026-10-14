// Test-only headless app process, compiled under build/ by E2EProcessHost.swift.
// Uses the production runtime and CardStore, never the user's defaults or socket.
import Foundation
import ZeusLink
import ZeusProtocol
import ZeusSprites

@MainActor private final class HostStatus: AvatarStatusControlling {
    func setOverride(_ state: AvatarState, detail: String?, progress: Double?, ttl: TimeInterval) {}
    func clearOverride() {}
    func setDeliveryProblem(_ message: String?) {}
}
@MainActor private final class HostCharacters: CharacterControlling {
    var availableCharacters: [SpriteCharacter] = []
    var currentCharacterID = "zeus"
}
@MainActor private final class HostRouting: AgentRoutingSettings {
    var assistantSessionKey: String? { nil }
    var preferredAgent: AgentKind? { nil }
    var deliveryMethod: DeliveryMethod = .channel
    var tmuxTarget: String? { nil }
    var openCodeBaseURL: URL? { nil }
    var openCodeServerPassword: String? { nil }
}

/// LV1 synthetic summaries only. Read receipts and announcements are independently observable.
@MainActor private final class HostLearnings: LearningsProviding {
    var learningsEnabled = true
    var onNewLearning: ((Learning) -> Void)?
    var items = [
        Learning(id: "lv1-digest", kind: .digest, createdAt: Date(timeIntervalSince1970: 1_700_000_000), text: "Fixture daily summary."),
        Learning(id: "lv1-moment", kind: .moment, createdAt: Date(timeIntervalSince1970: 1_700_000_001), text: "Fixture back from a break.")
    ]
    var readIDs: [String] = []
    func unreadLearnings() -> [Learning] { items }
    func markLearningsRead(through id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        readIDs.append(id); items.removeFirst(index + 1)
    }
    func add(_ learning: Learning) { items.append(learning); onNewLearning?(learning) }
}

/// AC1 real-CLI proof: records calls only in this private host's scratch directory.
@MainActor private final class HostAppControl: AppControlling {
    let root: URL
    init(root: URL) { self.root = root }
    var assistantMayControlApp: Bool { true }
    var assistantMayInstallUpdates: Bool { false }
    var appControlState: AppControlState {
        try? log("state", [:])
        return .init(version: "dev-ac1", build: "fixture", characterID: "zeus", themeID: "day", size: "medium", screen: 0,
            position: ["x": 10, "y": 20], screens: [["width": 1200, "height": 800, "scale": 2]], panelOpen: false,
            hidden: false, quietHoursActive: false, ghostMode: false, userIdleSeconds: 30,
            formats: ["character": "docs/design/SPRITE_FORMAT.md", "theme": "docs/design/THEME_FORMAT.md"])
    }
    private func log(_ name: String, _ payload: JSONValue) throws {
        var data = try ZeusJSON.encoder().encode(JSONValue.object(["call": .string(name), "payload": payload])); data.append(10)
        let url = root.appendingPathComponent("app-control.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    func move(to placement: AvatarPlacement) throws -> AppChange {
        guard placement == .nearActiveWindow else { throw AppControlError.invalidArgument("Fixture expects near-active-window") }
        try log("move", ["position": "near-active-window"])
        return .init(summary: "Moved Zeus near the active window", undoTitle: "Undo", undo: {})
    }
    func setCharacter(id: String) throws -> AppChange { throw AppControlError.unknownID(id) }
    func createCharacter(name: String, json: Data) throws -> AppChange { throw AppControlError.invalidFile("Fixture does not create files") }
    func setTheme(id: String) throws -> AppChange { throw AppControlError.unknownID(id) }
    func createTheme(name: String, json: Data) throws -> AppChange { throw AppControlError.invalidFile("Fixture does not create files") }
    func setSize(_ size: String) throws -> AppChange { throw AppControlError.invalidArgument("Fixture only moves Zeus") }
    func hide(minutes: Int?, untilTomorrow: Bool) throws -> AppChange { throw AppControlError.invalidArgument("Fixture only moves Zeus") }
    func setAppearance(_ patch: AppearancePatch) throws -> AppChange { throw AppControlError.invalidArgument("Fixture only moves Zeus") }
    func checkForUpdates() async throws -> UpdateCheckResult { .init(available: false) }
    func installUpdate(version: String) async throws { throw AppControlError.disabled(setting: "Fixture never installs") }
}

@main private struct RuntimeHost {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let routing = HostRouting(), learnings = HostLearnings()
        let live = ProcessInfo.processInfo.environment["ZEUS_LV1_HOST"] != nil
        let runtime = ZeusRuntime(cards: cards, status: HostStatus(), characters: HostCharacters(), routing: routing,
                                  socketPath: root.appendingPathComponent("bridge.sock").path,
                                  ledgerURL: root.appendingPathComponent("deliveries.json"),
                                  appControl: ProcessInfo.processInfo.environment["ZEUS_AC1_HOST"] == "1" ? HostAppControl(root: root) : nil,
                                  learnings: live ? learnings : nil)
        try runtime.start()
        let ready: JSONValue = ["ready": true, "socket": .string(runtime.socketPath),
                                "defaultSocket": .string(ZeusPaths.bridgeSocket.path), "wireVersion": .number(Double(wireVersion))]
        var frame = try ZeusJSON.encoder().encode(ready); frame.append(10)
        try FileHandle.standardOutput.write(contentsOf: frame)
        // Parent closes stdin to exercise the same clean runtime.stop path as app quit.
        if live {
            // Read on a worker; command execution and runtime timers remain on MainActor.
            await Task.detached {
                var line = Data()
                while let byte = try? FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
                    if byte[0] == 10 {
                        await command(line, cards: cards, routing: routing, learnings: learnings, runtime: runtime)
                        line.removeAll(keepingCapacity: true)
                    } else { line.append(byte) }
                }
            }.value
        } else { _ = await Task.detached { FileHandle.standardInput.readDataToEndOfFile() }.value }
        runtime.stop()
        await Task.yield()
    }

    @MainActor private static func command(_ data: Data, cards: CardStore, routing: HostRouting, learnings: HostLearnings, runtime: ZeusRuntime) {
        do {
            let request = try ZeusJSON.decoder().decode(JSONValue.self, from: data)
            var response: [String: JSONValue] = ["ok": true]
            switch request["command"] {
            case "skip":
                guard case .string(let id) = request["id"] else { throw CocoaError(.coderValueNotFound) }
                response["recorded"] = .bool(cards.respond(id: id, response: .init(device: .mac, skipped: true)))
            case "learning_enabled":
                guard case .bool(let enabled) = request["enabled"] else { throw CocoaError(.coderValueNotFound) }
                learnings.learningsEnabled = enabled
            case "learning_add":
                guard case .string(let id) = request["id"], case .string(let text) = request["text"] else { throw CocoaError(.coderValueNotFound) }
                learnings.add(.init(id: id, kind: .moment, createdAt: Date(timeIntervalSince1970: 1_700_000_002), text: text))
            case "routing":
                guard case .string(let value) = request["method"], let method = DeliveryMethod(rawValue: value) else { throw CocoaError(.coderValueNotFound) }
                routing.deliveryMethod = method; runtime.processDueDeliveries()
            case "state":
                response["cards"] = .array(cards.cards.map { ["id": .string($0.id), "title": .string($0.title ?? $0.body), "status": .string($0.status.rawValue), "skipped": .bool($0.response?.skipped == true)] })
                response["deliveries"] = .array((runtime.ledger?.records ?? []).map {
                    ["id": .string($0.delivery.id), "content": .string($0.delivery.content), "meta": .object($0.delivery.meta.mapValues(JSONValue.string)),
                     "attempts": .number(Double($0.delivery.attempts)), "acked": .bool($0.delivery.ackedAt != nil)]
                })
                response["sessions"] = .array(runtime.sessions.map { session in
                    ["key": .string(session.sessionKey), "channel": .bool(session.supportsChannel),
                     "learningNotifications": .bool(runtime.bridges[session.sessionKey]?.hello.capabilities.learningNotifications == true),
                     "pane": session.tmuxPane.map(JSONValue.string) ?? .null, "socket": session.tmuxSocketPath.map(JSONValue.string) ?? .null]
                })
                response["unread"] = .array(learnings.items.map { .string($0.id) })
                response["readThrough"] = .array(learnings.readIDs.map(JSONValue.string))
                response["waiters"] = .number(Double(runtime.waiters.count))
            default: throw CocoaError(.coderValueNotFound)
            }
            var output = try ZeusJSON.encoder().encode(JSONValue.object(response)); output.append(10)
            try FileHandle.standardOutput.write(contentsOf: output)
        } catch {
            let output: JSONValue = ["ok": false, "error": .string(error.localizedDescription)]
            if var data = try? ZeusJSON.encoder().encode(output) { data.append(10); try? FileHandle.standardOutput.write(contentsOf: data) }
        }
    }
}
