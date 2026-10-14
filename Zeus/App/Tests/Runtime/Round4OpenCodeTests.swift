import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round4OpenCodeTests {
    @Test func canonicalEndpointKeepsProxyAndRejectsUnscopedURLs() throws {
        let a = try #require(URL(string: "HTTP://LOCALHOST:80/proxy/"))
        #expect(OpenCodeDestination.canonicalEndpoint(a)?.absoluteString == "http://localhost/proxy")
        for value in ["http://user:password@localhost", "http://localhost?query=1", "http://localhost#fragment", "file:///tmp/server"] {
            #expect(URL(string: value).flatMap(OpenCodeDestination.canonicalEndpoint) == nil)
        }
    }
    @Test func selectionsOnDifferentServersNeverSilentlyRetarget() async throws {
        let routing = FakeRouting(), http = NativeOpenCodeHTTP()
        let session = connectorSession(agent: .opencode)
        routing.deliveryMethod = .opencode
        routing.openCodeBaseURL = URL(string: "http://localhost:4096/server-a")
        routing.openCodeSessionIDs[session.sessionKey] = "ses_A"
        routing.openCodeBaseURL = URL(string: "http://localhost:4097/server-b")
        let connector = OpenCodeConnector(transport: http, credentials: { nil })
        await #expect(throws: ConnectorError.mismatchedOpenCodeEndpoint) {
            try await connector.deliver(.init(kind: .reply, sessionKey: session.sessionKey, content: "Only A"), to: session, bridge: nil, routing: routing)
        }
        #expect(await http.calls.isEmpty)
        #expect(routing.openCodeDestination(for: session.sessionKey)?.endpoint.port == 4096)
    }
    @Test func validatedPinPersistsEndpointAndQueuesAcrossRelaunchAndServerChange() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let http = NativeOpenCodeHTTP(); await http.configure(postStatus: 503)
        f.routing.deliveryMethod = .opencode
        f.routing.openCodeBaseURL = URL(string: "http://localhost:4096/proxy/")
        let session = connectorSession(agent: .opencode)
        f.routing.openCodeSessionIDs[session.sessionKey] = "ses_A"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing,
            clock: f.clock, socketPath: f.directory.appendingPathComponent("pin.sock").path,
            ledgerURL: f.directory.appendingPathComponent("pin.json"),
            connectors: [OpenCodeConnector(transport: http, credentials: { nil })], targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(session)
        _ = await runtime.sendUserMessage("Keep the destination")
        let record = try #require(runtime.ledger?.records.first)
        #expect(record.delivery.meta["opencode_destination_validated"] == "true")
        #expect(record.delivery.meta["opencode_endpoint"] == "http://localhost:4096/proxy")
        #expect(try DeliveryLedger(location: runtime.ledgerURL).record(id: record.delivery.id)?.delivery.meta == record.delivery.meta)
        // Same native ID and cwd exist on B, but an uncertain A submission cannot go there.
        f.routing.openCodeBaseURL = URL(string: "http://localhost:4097/proxy")
        runtime.stop(); try runtime.start(); runtime.registerSession(session)
        try await eventually { runtime.sends.isEmpty }
        runtime.retryPendingDeliveries(); try await eventually { runtime.sends.isEmpty }
        #expect(await http.calls.allSatisfy { $0.url?.port == 4096 })
        #expect(runtime.ledger?.record(id: record.delivery.id)?.delivery.meta["opencode_endpoint"] == record.delivery.meta["opencode_endpoint"])
        // Retry now deliberately resets the counter; an endpoint mismatch consumes no attempt.
        #expect(runtime.ledger?.record(id: record.delivery.id)?.delivery.attempts == 0)
        #expect(runtime.userMessageDeliveries.first?.state == .queued)
        #expect(runtime.userMessageDeliveries.first?.reason?.contains("Change the server URL back") == true)
    }
    @Test func legacyValidatedIDWithoutEndpointNeverIssuesHTTP() async throws {
        let routing = FakeRouting(), http = NativeOpenCodeHTTP(), session = connectorSession(agent: .opencode)
        routing.deliveryMethod = .opencode; routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        routing.openCodeSessionIDs[session.sessionKey] = "ses_A"
        let delivery = Delivery(kind: .reply, sessionKey: session.sessionKey, content: "Unverified old destination",
            meta: ["opencode_session_id": "ses_A", "opencode_destination_validated": "true"])
        await #expect(throws: ConnectorError.unverifiedOpenCodeDestination) {
            try await OpenCodeConnector(transport: http, credentials: { nil }).deliver(delivery, to: session, bridge: nil, routing: routing)
        }
        #expect(await http.calls.isEmpty)
    }
}

/// Server A stores the message but loses both its POST receipt and subsequent reads.
private actor UncertainEndpointHTTP: ConnectorHTTPTransport {
    let native = NativeOpenCodeHTTP()
    var posted = false
    var loseReceipt = true
    var requests: [URLRequest] = []
    func restoreReceipt() { loseReceipt = false }
    func send(_ request: URLRequest) async throws -> ConnectorHTTPResult {
        requests.append(request)
        if posted && loseReceipt && request.url?.pathComponents.contains("message") == true { throw ConnectorError.processIO }
        let result = try await native.send(request)
        if request.httpMethod == "POST" {
            posted = true
            if loseReceipt { throw ConnectorError.processIO }
        }
        return result
    }
}

extension Round4OpenCodeTests {
    @Test func lostAcceptedPostCannotReplayOnClonedServerAndRecoversOnOriginalEndpoint() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let http = UncertainEndpointHTTP()
        let a = try #require(URL(string: "http://localhost:4096")), b = try #require(URL(string: "http://localhost:4097"))
        f.routing.deliveryMethod = .opencode; f.routing.openCodeBaseURL = a
        let session = connectorSession(agent: .opencode)
        f.routing.openCodeSessionIDs[session.sessionKey] = "ses_cloned"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing,
            clock: f.clock, socketPath: f.directory.appendingPathComponent("uncertain.sock").path,
            ledgerURL: f.directory.appendingPathComponent("uncertain.json"),
            connectors: [OpenCodeConnector(transport: http, credentials: { nil })], targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(session)
        _ = await runtime.sendUserMessage("Send exactly once to A")
        let id = try #require(runtime.ledger?.records.first?.delivery.id)
        #expect(await http.native.saved.count == 1)
        #expect(runtime.ledger?.record(id: id)?.delivery.meta["opencode_endpoint"] == a.absoluteString)
        f.routing.openCodeBaseURL = b
        runtime.stop(); try runtime.start(); runtime.registerSession(session)
        runtime.retryPendingDeliveries(); try await eventually { runtime.sends.isEmpty }
        #expect(await http.requests.allSatisfy { $0.url?.port == 4096 })
        #expect(await http.requests.filter { $0.httpMethod == "POST" }.count == 1)
        await http.restoreReceipt(); f.routing.openCodeBaseURL = a
        runtime.retryPendingDeliveries()
        try await eventually { runtime.sends.isEmpty && runtime.userMessageDeliveries.first?.state == .delivered }
        #expect(await http.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(await http.native.saved.count == 1)
    }
}

extension Round4OpenCodeTests {
    @Test(arguments: [false, true])
    func mixedDeadQueueKeepsAcceptedAndUncertainNativePins(uncertain: Bool) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let http = UncertainEndpointHTTP()
        if !uncertain { await http.restoreReceipt() }
        let origin = "opencode:/assistant#101.1000"
        let replacement = "opencode:/assistant#102.1000"
        f.routing.deliveryMethod = .opencode
        f.routing.openCodeBaseURL = URL(string: "http://server-a.test:4096")
        f.routing.openCodeSessionIDs[origin] = "ses_A"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing,
            clock: f.clock, socketPath: f.directory.appendingPathComponent("mixed.sock").path,
            ledgerURL: f.directory.appendingPathComponent("mixed.json"),
            connectors: [OpenCodeConnector(transport: http, credentials: { nil })], targetIsDead: { $0 == origin })
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(.init(id: UUID(), sessionKey: origin, agent: .opencode, cwd: "/assistant", clientName: nil,
            supportsChannel: false, tmuxPane: nil, connectedAt: f.clock.now))
        _ = await runtime.sendUserMessage("Already accepted on A", deliveryID: "d_pinned")
        let pinned = try #require(runtime.ledger?.record(id: "d_pinned"))
        #expect(pinned.delivery.meta["opencode_destination_validated"] == "true")
        #expect((pinned.transportDeliveredAt == nil) == uncertain)
        #expect(await http.native.saved.count == 1)
        f.routing.deliveryMethod = .polling
        _ = await runtime.sendUserMessage("Not sent yet", deliveryID: "d_sibling")
        runtime.unregisterSession(id: try #require(runtime.sessions.first?.id), sessionKey: origin)
        runtime.retargetDeadUserMessages()
        let retained = try #require(runtime.ledger?.record(id: "d_pinned"))
        #expect(retained.delivery == pinned.delivery)
        #expect(retained.transportDeliveredAt == pinned.transportDeliveredAt)
        #expect(retained.awaitingAssistant == pinned.awaitingAssistant)
        #expect(runtime.ledger?.record(id: "d_sibling")?.awaitingAssistant == true)
        #expect(runtime.ledger?.record(id: "d_sibling")?.delivery.sessionKey == "")
        f.routing.deliveryMethod = .opencode
        f.routing.openCodeBaseURL = URL(string: "http://server-b.test:4096")
        f.routing.openCodeSessionIDs[replacement] = "ses_B"
        runtime.registerSession(.init(id: UUID(), sessionKey: replacement, agent: .opencode, cwd: "/assistant", clientName: nil,
            supportsChannel: false, tmuxPane: nil, connectedAt: f.clock.now))
        runtime.processDueDeliveries()
        try await eventually { runtime.sends.isEmpty }
        let requests = await http.requests
        #expect(requests.filter { $0.httpMethod == "POST" && $0.url?.host == "server-a.test" }.count == 1)
        #expect(requests.filter { $0.httpMethod == "POST" && $0.url?.host == "server-b.test" }.allSatisfy {
            $0.url?.path == "/session/ses_B/prompt_async"
                && String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("Not sent yet")
        })
        let reloaded = try DeliveryLedger(location: runtime.ledgerURL)
        #expect(reloaded.record(id: "d_pinned")?.delivery == pinned.delivery)
        #expect(reloaded.record(id: "d_pinned")?.transportDeliveredAt == pinned.transportDeliveredAt)
        #expect(reloaded.record(id: "d_sibling")?.delivery.sessionKey == replacement)
    }

    @Test func nativePinCannotRetargetADeadSessionOrSwitchToTmux() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let origin = "opencode:/dead#1.2"
        f.routing.preferredAgent = .claude
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing,
            clock: f.clock, socketPath: f.directory.appendingPathComponent("handoff.sock").path,
            ledgerURL: f.directory.appendingPathComponent("handoff.json"), connectors: [f.connector], targetIsDead: { $0 == origin })
        try runtime.start(); defer { runtime.stop() }
        let meta = ["opencode_session_id": "ses_A", "opencode_endpoint": "http://localhost:4096", "opencode_destination_validated": "true"]
        for kind in [Delivery.Kind.userMessage, .reply] {
            let delivery = Delivery(kind: kind, sessionKey: origin, content: "Uncertain original send", meta: meta, createdAt: f.clock.now.addingTimeInterval(-121))
            try runtime.ledger?.insert(.init(delivery: delivery, disconnectedAt: f.clock.now.addingTimeInterval(-121)))
        }
        runtime.registerSession(.init(id: UUID(), sessionKey: "claude:/new#3.4", agent: .claude, cwd: "/new", clientName: nil,
            supportsChannel: true, tmuxPane: nil, connectedAt: f.clock.now))
        runtime.processDueDeliveries()
        #expect(runtime.ledger?.records.allSatisfy { $0.delivery.sessionKey == origin && $0.delivery.meta == meta } == true)
        #expect(f.connector.deliveries.isEmpty)
        f.routing.deliveryMethod = .tmux
        runtime.registerSession(.init(id: UUID(), sessionKey: origin, agent: .opencode, cwd: "/dead", clientName: nil,
            supportsChannel: false, tmuxPane: "%0", connectedAt: f.clock.now, tmuxSocketPath: "/test/tmux.sock"))
        runtime.processDueDeliveries()
        #expect(runtime.ledger?.records.allSatisfy { $0.delivery.attempts == 0 && $0.delivery.meta == meta } == true)
        #expect(f.connector.deliveries.isEmpty)
    }
}
