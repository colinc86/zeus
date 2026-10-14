import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct ConnectOwnRoutingTests {
    @Test(arguments: [DeliveryMethod.channel, .tmux, .opencode, .polling])
    func claudeCapabilityDoesNotOverrideSelectedTransport(method: DeliveryMethod) async throws {
        let f = try RuntimeFixture()
        f.runtime.stop()
        let runner = FakeProcessRunner()
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters,
            routing: f.routing, clock: f.clock, socketPath: f.runtime.socketPath, ledgerURL: f.runtime.ledgerURL,
            connectors: [ChannelDeliveryConnector(), TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner), OpenCodeConnector()],
            targetIsDead: { _ in false })
        defer { runtime.stop(); f.stop() }
        f.routing.deliveryMethod = method
        try runtime.start()
        let client = BridgeClient(socketPath: runtime.socketPath)
        var pushes: [AgentPush] = []
        let hello = BridgeHello(agent: .claude, pid: 1, ppid: 45, cwd: "/assistant",
            client: .init(name: "Connect-own regression", version: "1"), capabilities: .init(channel: true),
            tmuxPane: "%0", parentStartTime: 123, tmuxSocketPath: "/test/tmux.sock")
        do {
            _ = try await client.start(hello: hello, onPush: { push in
                await MainActor.run { pushes.append(push) }
                try? await client.reportPushWritten(deliveryID: push.deliveryID)
            })
            try await eventually { runtime.sessions.count == 1 }
            let selected = runtime.transport(for: hello.sessionKey)?.0
            switch method {
            case .channel: #expect(selected is ChannelDeliveryConnector)
            case .tmux: #expect(selected is TmuxConnector)
            case .opencode, .polling: #expect(selected == nil)
            }
            let result = await runtime.sendUserMessage("Use the selected transport", deliveryID: "d_connect_own")
            if method == .channel || method == .tmux { #expect(result == .delivered) }
            else if case .queued = result { } else { Issue.record("Unavailable route must keep the message queued") }
            #expect(pushes.count == (method == .channel ? 1 : 0))
            let calls = await runner.calls
            #expect(calls.contains { $0.arguments.first == "send-keys" } == (method == .tmux))
            await client.stop()
        } catch { await client.stop(); throw error }
    }
}
