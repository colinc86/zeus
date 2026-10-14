import Foundation
import Testing
@testable import ZeusProtocol

struct TurnEndedWireTests {
    @Test func flatEnvelopeAndReceiptRoundTrip() throws {
        let event = TurnEnded(agent: .claude, pid: 22, ppid: 21, cwd: "/fixture", ancestors: [.init(pid: 21, startTime: 123)],
            firedAt: 1234.56789, reason: .interrupted, tmuxPane: "%0", nativeSessionID: "native", deliveryID: "d_1")
        let data = try ZeusJSON.encoder().encode(WireMessage.turnEnded(event))
        let object = try ZeusJSON.decoder().decode(JSONValue.self, from: data)
        #expect(object["type"] == "turnEnded" && object["pid"] == 22)
        #expect(try ZeusJSON.decoder().decode(WireMessage.self, from: data) == .turnEnded(event))
        let receipt = WireMessage.turnEndedReceipt(.init())
        #expect(try ZeusJSON.decoder().decode(WireMessage.self, from: ZeusJSON.encoder().encode(receipt)) == receipt)
    }
    @Test func settingsAreLaunchOnlyQuotedAndBounded() throws {
        let path = "/fixture/Zeus's app/bridge", socket = "/fixture/socket's path"
        let settings = try ZeusJSON.decoder().decode(JSONValue.self, from: Data(AgentTurnHooks.claudeSettings(bridgePath: path, socketPath: socket).utf8))
        #expect(settings["hooks"]?["Stop"] != nil && settings["hooks"]?["StopFailure"] != nil)
        let text = try AgentTurnHooks.claudeSettings(bridgePath: path, socketPath: socket)
        #expect(text.contains("--turn-ended") && !text.contains("disableAllHooks"))
        #expect(try ZeusJSON.decoder().decode([String].self, from: Data(AgentTurnHooks.codexNotify(bridgePath: path, socketPath: socket).utf8)) == [path, "--turn-ended", "--agent", "codex", "--socket", socket])
        #expect(try AgentTurnHooks.openCodePlugin(bridgePath: path, socketPath: socket).contains("session.idle"))
    }
}
