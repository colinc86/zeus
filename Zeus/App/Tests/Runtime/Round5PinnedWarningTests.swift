import Foundation
import Testing
import ZeusDesign
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5PinnedWarningTests {
    @Test func oldOpenCodePinRaisesAnIssueWithDiscardAndNoUselessRetry() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.routing.deliveryMethod = .opencode
        f.routing.openCodeBaseURL = URL(string: "http://localhost:4097")
        let session = connectorSession(agent: .opencode)
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
            socketPath: f.directory.appendingPathComponent("pin.sock").path, ledgerURL: f.directory.appendingPathComponent("pin.json"),
            connectors: [OpenCodeConnector(transport: FakeHTTPTransport(), credentials: { nil })], targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop() }; runtime.registerSession(session)
        try runtime.ledger?.insert(.init(delivery: .init(id: "d_old", kind: .userMessage, sessionKey: session.sessionKey, content: "Waiting",
            meta: ["opencode_destination_validated": "true", "opencode_session_id": "ses_old", "opencode_endpoint": "http://localhost:4096"], createdAt: f.clock.now)))
        runtime.processDueDeliveries()
        #expect(runtime.deliveryIssue == nil)
        f.clock.advance(121, wake: false); runtime.processDueDeliveries()
        #expect(runtime.deliveryIssue?.detail.contains("localhost:4096") == true)
        #expect(runtime.deliveryIssue?.detail.contains("discard") == true)
        #expect(!runtime.canRetryPendingDeliveries)
        let held = try #require(runtime.ledger?.record(id: "d_old"))
        #expect(held.delivery.meta == ["opencode_destination_validated": "true", "opencode_session_id": "ses_old", "opencode_endpoint": "http://localhost:4096"])
        #expect(held.queueReasonSource == .nativeRoute)
        let restoredLedger = try DeliveryLedger(location: runtime.ledgerURL)
        #expect(restoredLedger.record(id: "d_old")?.queueReasonSource == .nativeRoute)
        #expect(restoredLedger.record(id: "d_old")?.delivery == held.delivery)
        f.routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        runtime.processDueDeliveries()
        #expect(runtime.deliveryIssue == nil)
        if let active = runtime.sends["d_old"] { _ = await active.value }
        #expect(runtime.canRetryPendingDeliveries)
        #expect(runtime.userMessageDeliveries.first?.reason?.contains("Change the server URL back") == false)
        runtime.discardPendingDeliveries()
        #expect(runtime.deliveryIssue == nil && runtime.ledger?.record(id: "d_old")?.discardedAt != nil)
    }

}
