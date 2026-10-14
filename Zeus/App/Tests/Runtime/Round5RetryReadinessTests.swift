import Foundation
import Testing
import ZeusDesign
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5RetryReadinessTests {
    @Test func retryRequiresOpenCodeSelectionAndInstalledTmux() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .opencode; f.routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        let session = connectorSession(agent: .opencode)
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
            socketPath: f.directory.appendingPathComponent("retry.sock").path, ledgerURL: f.directory.appendingPathComponent("retry.json"),
            connectors: [OpenCodeConnector(transport: FakeHTTPTransport(), credentials: { nil }), TmuxConnector(executable: nil)], targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop() }; runtime.registerSession(session)
        try runtime.ledger?.insert(.init(delivery: .init(id: "d_ready", kind: .userMessage, sessionKey: session.sessionKey, content: "Wait", createdAt: f.clock.now)))
        #expect(!runtime.canRetryPendingDeliveries)
        f.routing.openCodeSessionIDs[session.sessionKey] = "ses_ready"
        #expect(runtime.canRetryPendingDeliveries)
        f.routing.openCodeBaseURL = URL(string: "http://localhost:4097")
        #expect(!runtime.canRetryPendingDeliveries)
        f.routing.deliveryMethod = .tmux; f.routing.tmuxTarget = "%0"
        #expect(!runtime.canRetryPendingDeliveries)
        let available = TmuxConnector(executable: URL(fileURLWithPath: "/bin/cat"))
        #expect(available.canRetryDelivery(to: session, bridge: nil, routing: f.routing))
        f.routing.tmuxTargetSocketPath = "/different/tmux.sock"
        #expect(!available.canRetryDelivery(to: session, bridge: nil, routing: f.routing))
    }

}
