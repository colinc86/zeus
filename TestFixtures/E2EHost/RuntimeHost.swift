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

@main private struct RuntimeHost {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let runtime = ZeusRuntime(cards: cards, status: HostStatus(), characters: HostCharacters(), routing: HostRouting(),
                                  socketPath: root.appendingPathComponent("bridge.sock").path,
                                  ledgerURL: root.appendingPathComponent("deliveries.json"))
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
