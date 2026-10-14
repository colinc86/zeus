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
    var deliveryMethod: DeliveryMethod { .channel }
    var tmuxTarget: String? { nil }
    var openCodeBaseURL: URL? { nil }
    var openCodeServerPassword: String? { nil }
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
        let runtime = ZeusRuntime(cards: cards, status: HostStatus(), characters: HostCharacters(), routing: HostRouting(),
                                  socketPath: root.appendingPathComponent("bridge.sock").path,
                                  ledgerURL: root.appendingPathComponent("deliveries.json"),
                                  appControl: ProcessInfo.processInfo.environment["ZEUS_AC1_HOST"] == "1" ? HostAppControl(root: root) : nil)
        try runtime.start()
        let ready: JSONValue = ["ready": true, "socket": .string(runtime.socketPath),
                                "defaultSocket": .string(ZeusPaths.bridgeSocket.path), "wireVersion": .number(Double(wireVersion))]
        var frame = try ZeusJSON.encoder().encode(ready); frame.append(10)
        try FileHandle.standardOutput.write(contentsOf: frame)
        // Parent closes stdin to exercise the same clean runtime.stop path as app quit.
        _ = await Task.detached { FileHandle.standardInput.readDataToEndOfFile() }.value
        runtime.stop()
        await Task.yield()
    }
}
