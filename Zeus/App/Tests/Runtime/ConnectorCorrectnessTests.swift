import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

actor NativeOpenCodeHTTP: ConnectorHTTPTransport {
    var calls: [URLRequest] = []
    var saved: [String: JSONValue] = [:]
    var failAfterSave = false
    var postStatus = 204
    var directory = "/assistant"
    var infoStatus = 200
    var malformedMessage = false
    var partialSaveOnce = false
    var pauseNext = false
    var paused: CheckedContinuation<Void, Never>?
    func pause() { pauseNext = true }
    func release() { paused?.resume(); paused = nil }
    func failPartSaveOnce() { partialSaveOnce = true }
    func configure(failAfterSave: Bool = false, postStatus: Int = 204, directory: String = "/assistant", infoStatus: Int = 200, malformedMessage: Bool = false) {
        self.failAfterSave = failAfterSave; self.postStatus = postStatus; self.directory = directory
        self.infoStatus = infoStatus; self.malformedMessage = malformedMessage
    }
    func send(_ request: URLRequest) async throws -> ConnectorHTTPResult {
        calls.append(request)
        if pauseNext { pauseNext = false; await withCheckedContinuation { paused = $0 } }
        let url = try #require(request.url)
        let path = url.pathComponents
        if url.lastPathComponent == "prompt_async" {
            let body = try ZeusJSON.decoder().decode(JSONValue.self, from: #require(request.httpBody))
            let id = try e2eString(body["messageID"])
            if partialSaveOnce {
                partialSaveOnce = false; saved[id] = ["info": ["id": .string(id), "role": "user"], "parts": []]
                return .init(status: 503, body: Data())
            }
            if postStatus == 204 { saved[id] = ["info": ["id": .string(id), "role": "user"], "parts": body["parts"] ?? []] }
            if failAfterSave { throw ConnectorError.processIO }
            return .init(status: postStatus, body: Data())
        }
        if path.contains("message") {
            if malformedMessage { return .init(status: 200, body: Data("true".utf8)) }
            if let value = saved[url.lastPathComponent] { return .init(status: 200, body: try ZeusJSON.encoder().encode(value)) }
            return .init(status: 404, body: Data())
        }
        return .init(status: infoStatus, body: try ZeusJSON.encoder().encode(JSONValue.object(["id": .string(url.lastPathComponent), "directory": .string(directory)])))
    }
}

@MainActor struct ConnectorCorrectnessTests {
    private func openCodeRouting(_ session: ConnectedSession) -> FakeRouting {
        let routing = FakeRouting(); routing.deliveryMethod = .opencode
        routing.openCodeBaseURL = URL(string: "http://localhost:4096/proxy")
        routing.openCodeSessionIDs[session.sessionKey] = "ses_exact"
        return routing
    }
    @Test func nativeOpenCodeTargetsExactSessionAndNeverTouchesTUIPrompt() async throws {
        let http = NativeOpenCodeHTTP(); let connector = OpenCodeConnector(transport: http, credentials: { nil })
        let session = connectorSession(agent: .opencode); let routing = openCodeRouting(session)
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "User message")
        try await connector.deliver(delivery, to: session, bridge: nil, routing: routing)
        let calls = await http.calls
        #expect(calls.map { $0.httpMethod } == ["GET", "GET", "POST", "GET"])
        #expect(calls[2].url?.path == "/proxy/session/ses_exact/prompt_async")
        #expect(!calls.contains { $0.url?.path.contains("tui") == true })
        #expect(calls.allSatisfy { URLComponents(url: $0.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "directory", value: session.cwd)] })
        let body = try ZeusJSON.decoder().decode(JSONValue.self, from: #require(calls[2].httpBody))
        #expect(body["parts"]?[0]?["text"] == .string(AgentInjectionText.format(delivery)))
        #expect(body["messageID"] == .string(OpenCodeConnector.nativeID(prefix: "msg", delivery: delivery, sessionID: "ses_exact")))
        #expect(body["parts"]?[0]?["id"] == .string(OpenCodeConnector.nativeID(prefix: "prt", delivery: delivery, sessionID: "ses_exact")))
    }
    @Test func lostHTTPReceiptAndFreshConnectorRetryCreateOneMessageAndOnePart() async throws {
        let http = NativeOpenCodeHTTP(); await http.configure(failAfterSave: true)
        let session = connectorSession(agent: .opencode), routing = openCodeRouting(session)
        let delivery = Delivery(kind: .reply, sessionKey: session.sessionKey, content: "Answer once")
        try await OpenCodeConnector(transport: http, credentials: { nil }).deliver(delivery, to: session, bridge: nil, routing: routing)
        try await OpenCodeConnector(transport: http, credentials: { nil }).deliver(delivery, to: session, bridge: nil, routing: routing)
        #expect(await http.calls.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(await http.saved.count == 1)
    }
    @Test func failedPromptRetriesWithStableIDsAndNoAppendStage() async throws {
        let http = NativeOpenCodeHTTP(); await http.configure(postStatus: 503)
        let session = connectorSession(agent: .opencode), routing = openCodeRouting(session)
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "Retry")
        let connector = OpenCodeConnector(transport: http, credentials: { nil })
        await #expect(throws: ConnectorError.httpStatus(503)) { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        await http.configure()
        try await connector.deliver(delivery, to: session, bridge: nil, routing: routing)
        let posts = await http.calls.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2 && posts[0].httpBody == posts[1].httpBody)
        #expect(await http.saved.count == 1)
    }
    @Test func missingOrWrongSessionNeverSendsAndOtherAgentsCannotUseOpenCode() async throws {
        let http = NativeOpenCodeHTTP(); let connector = OpenCodeConnector(transport: http, credentials: { nil })
        let session = connectorSession(agent: .opencode), routing = openCodeRouting(session)
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "Keep queued")
        routing.openCodeSessionIDs = [:]
        await #expect(throws: ConnectorError.missingOpenCodeSession) { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        #expect(await http.calls.isEmpty)
        routing.openCodeSessionIDs[session.sessionKey] = "ses_exact"
        await http.configure(directory: "/another")
        await #expect(throws: ConnectorError.mismatchedOpenCodeSession) { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        #expect(await http.calls.count == 1)
        #expect(!connector.canDeliver(to: connectorSession(agent: .codex), bridge: nil, routing: routing))
    }
    @Test func twoSameFolderSessionsUseDistinctExplicitNativeTargets() async throws {
        let http = NativeOpenCodeHTTP(); let connector = OpenCodeConnector(transport: http, credentials: { nil })
        let a = ConnectedSession(id: UUID(), sessionKey: "opencode:/assistant#1.2", agent: .opencode, cwd: "/assistant", clientName: "A", supportsChannel: false, tmuxPane: nil, connectedAt: Date())
        let b = ConnectedSession(id: UUID(), sessionKey: "opencode:/assistant#3.4", agent: .opencode, cwd: "/assistant", clientName: "B", supportsChannel: false, tmuxPane: nil, connectedAt: Date())
        let routing = openCodeRouting(a); routing.openCodeSessionIDs[a.sessionKey] = "ses_A"; routing.openCodeSessionIDs[b.sessionKey] = "ses_B"
        let delivery = Delivery(id: "d_shared", kind: .userMessage, sessionKey: a.sessionKey, content: "Same ID, scoped destination")
        try await connector.deliver(delivery, to: a, bridge: nil, routing: routing)
        try await connector.deliver(delivery, to: b, bridge: nil, routing: routing)
        #expect(await http.calls.filter { $0.httpMethod == "POST" }.map { $0.url?.path } == ["/proxy/session/ses_A/prompt_async", "/proxy/session/ses_B/prompt_async"])
        #expect(await http.saved.count == 2)
    }
    @Test func credentialsAreSnapshottedPerSendAndURLsRemainValidated() async throws {
        let http = NativeOpenCodeHTTP(); let connector = OpenCodeConnector(transport: http, credentials: { .init(password: "fallback") })
        let session = connectorSession(agent: .opencode), routing = openCodeRouting(session)
        for (index, password) in (["keychain", "changed", "", nil] as [String?]).enumerated() {
            routing.openCodeServerPassword = password
            let delivery = Delivery(id: "d_auth_\(index)", kind: .userMessage, sessionKey: session.sessionKey, content: "Auth")
            try await connector.deliver(delivery, to: session, bridge: nil, routing: routing)
            let expected = password ?? "fallback"
            #expect(await http.calls.last?.value(forHTTPHeaderField: "Authorization") == (expected.isEmpty ? nil : "Basic " + Data(("opencode:" + expected).utf8).base64EncodedString()))
        }
        for url in [nil, URL(string: "file:///tmp/test"), URL(string: "http://user:pass@localhost:4096"), URL(string: "http://localhost:4096/#fragment")] {
            routing.openCodeBaseURL = url; #expect(!connector.canDeliver(to: session, bridge: nil, routing: routing))
        }
    }
    @Test func busyOrUnrecognizedInputAndDraftAtHomeNeverCountAsEmpty() throws {
        func state(_ line: String, x: Int) throws -> TmuxInputSnapshot { try #require(TmuxInputSnapshot(metadata: Data("\(x)|0|160|0|1\n".utf8), screen: Data(line.utf8))) }
        #expect(try state("› DRAFT_SENTINEL", x: 16).isEmpty == false)
        #expect(try state("› DRAFT_SENTINEL", x: 2).isEmpty == false)
        #expect(try state("› Ask Codex to do anything", x: 2).isEmpty == false)
        #expect(try state("› \u{001b}[2mAsk Codex to do anything\u{001b}[22m", x: 2).isEmpty)
        #expect(try state("❯ \n────────\n  ? shortcuts", x: 2).isEmpty)
        #expect(try state("› \n\nHidden multiline draft", x: 2).isEmpty == false)
        #expect(try state("❯ \n\nHidden multiline draft\n────────", x: 2).isEmpty == false)
        #expect(try state("shell$ ", x: 7).isEmpty == false)
        #expect(TmuxInputSnapshot(metadata: Data("2|0|160|0|0".utf8), screen: Data("› ".utf8)) == nil)
    }
    @Test func postponedInputDoesNotExhaustAttemptsAndRetryIsBounded() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let runner = FakeProcessRunner()
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing, clock: f.clock,
                                  socketPath: f.directory.appendingPathComponent("busy.sock").path,
                                  ledgerURL: f.directory.appendingPathComponent("busy-ledger.json"),
                                  connectors: [TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)])
        f.routing.deliveryMethod = .tmux; f.routing.tmuxTarget = "%0"
        await runner.setScreen("› Human draft")
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(connectorSession())
        if case .queued = await runtime.sendUserMessage("Wait") {} else { Issue.record("Expected queue") }
        let id = try #require(runtime.ledger?.records.first?.delivery.id)
        #expect(runtime.ledger?.record(id: id)?.delivery.attempts == 0)
        let count = await runner.calls.count
        runtime.processDueDeliveries(); #expect(await runner.calls.count == count)
        for _ in 0..<8 { f.clock.advance(5); runtime.processDueDeliveries(); try await eventually { runtime.sends.isEmpty } }
        #expect(runtime.ledger?.record(id: id)?.delivery.attempts == 0 && runtime.deliveryIssue == nil)
        #expect(await runner.calls.allSatisfy { !["paste-buffer", "send-keys"].contains($0.arguments.first ?? "") })
        await runner.setScreen(""); f.clock.advance(5); runtime.processDueDeliveries()
        try await eventually { runtime.ledger?.record(id: id)?.delivery.attempts == 1 && runtime.sends.isEmpty }
        #expect(await runner.calls.contains { $0.arguments.first == "send-keys" })
    }
    @Test func autoGroupsUnmappedOpenCodeFolderButExactSelectionsStayIndependent() throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        f.connect("opencode:/assistant#1.2", channel: false, agent: .opencode)
        f.connect("opencode:/assistant#3.4", channel: false, agent: .opencode)
        #expect(f.runtime.assistantCandidates.count == 1 && f.runtime.assistantTarget == "opencode:/assistant#3.4")
        f.routing.openCodeSessionIDs["opencode:/assistant#1.2"] = "ses_A"
        f.routing.openCodeSessionIDs["opencode:/assistant#3.4"] = "ses_B"
        #expect(f.runtime.assistantCandidates.count == 2)
    }
    @Test func humanEditDuringPasteSuppressesEnter() async throws {
        let runner = FakeProcessRunner(); await runner.appendAfterPaste(" Human draft")
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        let session = connectorSession(), routing = FakeRouting()
        routing.deliveryMethod = .tmux; routing.tmuxTarget = "%0"
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "Envelope")
        await #expect(throws: ConnectorError.inputChanged) { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        #expect(await runner.calls.contains { $0.arguments.first == "paste-buffer" })
        #expect(await runner.calls.allSatisfy { $0.arguments.first != "send-keys" })
    }
    @Test func RGBColorParametersCannotMasqueradeAsADimPlaceholder() throws {
        let state = try #require(TmuxInputSnapshot(metadata: Data("2|0|160|0|1".utf8), screen: Data("› \u{001b}[38;2;255;2;255mAsk Codex to do anything".utf8)))
        #expect(!state.isEmpty)
    }

    @Test func partialNativeMessageSaveRepairsPartWithoutCreatingAnotherMessage() async throws {
        let http = NativeOpenCodeHTTP(); await http.failPartSaveOnce()
        let session = connectorSession(agent: .opencode), routing = openCodeRouting(session)
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "Repair partial save")
        let connector = OpenCodeConnector(transport: http, credentials: { nil })
        await #expect(throws: ConnectorError.httpStatus(503)) { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        try await connector.deliver(delivery, to: session, bridge: nil, routing: routing)
        #expect(await http.saved.count == 1)
        let posts = await http.calls.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2 && posts[0].httpBody == posts[1].httpBody)
        let saved = try #require(await http.saved.values.first)
        #expect(saved["parts"]?[0]?["text"] == .string(AgentInjectionText.format(delivery)))
    }

    @Test func nativeDestinationIsPinnedBeforeIOAndSurvivesSettingsChangeAndRestart() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let http = NativeOpenCodeHTTP(); await http.configure(postStatus: 503)
        let routing = f.routing; routing.deliveryMethod = .opencode; routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        let session = connectorSession(agent: .opencode)
        routing.openCodeSessionIDs[session.sessionKey] = "ses_A"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: routing, clock: f.clock,
                                  socketPath: f.directory.appendingPathComponent("native.sock").path,
                                  ledgerURL: f.directory.appendingPathComponent("native-ledger.json"),
                                  connectors: [OpenCodeConnector(transport: http, credentials: { nil })], targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(session)
        if case .queued = await runtime.sendUserMessage("Pinned") {} else { Issue.record("Expected uncertain transport") }
        let record = try #require(runtime.ledger?.records.first)
        #expect(record.delivery.meta["opencode_session_id"] == "ses_A")
        #expect(record.delivery.meta["opencode_created_ms"] != nil)
        routing.openCodeSessionIDs[session.sessionKey] = "ses_B"
        runtime.stop(); try runtime.start(); runtime.registerSession(session)
        try await eventually { runtime.sends.isEmpty }
        #expect(await http.calls.filter { $0.httpMethod == "POST" }.allSatisfy { $0.url?.path == "/session/ses_A/prompt_async" })
        await http.configure(); runtime.retryPendingDeliveries()
        try await eventually { runtime.sends.isEmpty }
        #expect(await http.calls.filter { $0.httpMethod == "POST" }.allSatisfy { $0.url?.path == "/session/ses_A/prompt_async" })
        #expect(runtime.ledger?.record(id: record.delivery.id)?.delivery.meta == record.delivery.meta)
    }

    @Test func hiddenDraftBelowCursorPreventsEnterAfterPaste() throws {
        let before = try #require(TmuxInputSnapshot(metadata: Data("2|0|160|0|1".utf8), screen: Data("› \u{001b}[2mAsk Codex to do anything\u{001b}[22m\n\nfooter".utf8)))
        #expect(before.isEmpty)
        // Extra input is inside the composer, above its blank separator. Text
        // below the separator is footer content and must not gate delivery.
        let after = try #require(TmuxInputSnapshot(metadata: Data("8|0|160|0|1".utf8), screen: Data("› Pasted\n  Human draft\n\nfooter".utf8)))
        #expect(!after.containsOnlyPaste("Pasted", after: before))
    }

    @Test func wrappedPastePreservesSpacesAndComposerSuffix() throws {
        let before = try #require(TmuxInputSnapshot(metadata: Data("2|0|10|0|1".utf8), screen: Data("› \u{001b}[2mAsk Codex to do anything\u{001b}[22m\n\nfooter".utf8)))
        let after = try #require(TmuxInputSnapshot(metadata: Data("3|1|10|0|1".utf8), screen: Data("› hello wo\nrld\n\nfooter".utf8)))
        #expect(after.containsOnlyPaste("hello world", after: before))
    }

    @Test func invalidNativeSelectionCanBeCorrectedWithoutRestartOrDiscard() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let http = NativeOpenCodeHTTP(); await http.configure(directory: "/wrong-folder")
        let routing = f.routing; routing.deliveryMethod = .opencode; routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        let session = connectorSession(agent: .opencode)
        routing.openCodeSessionIDs[session.sessionKey] = "ses_wrong"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: routing, clock: f.clock,
                                  socketPath: f.directory.appendingPathComponent("selection.sock").path,
                                  ledgerURL: f.directory.appendingPathComponent("selection-ledger.json"),
                                  connectors: [OpenCodeConnector(transport: http, credentials: { nil })], targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(session)
        if case .queued = await runtime.sendUserMessage("Correct selection") {} else { Issue.record("Expected preflight queue") }
        let id = try #require(runtime.ledger?.records.first?.delivery.id)
        #expect(runtime.ledger?.record(id: id)?.delivery.meta["opencode_session_id"] == nil)
        #expect(runtime.ledger?.record(id: id)?.delivery.attempts == 0)
        routing.openCodeSessionIDs[session.sessionKey] = "ses_correct"
        await http.configure(); f.clock.advance(5); runtime.processDueDeliveries()
        try await eventually { runtime.sends.isEmpty && runtime.ledger?.record(id: id)?.delivery.attempts == 1 }
        #expect(await http.calls.filter { $0.httpMethod == "POST" }.map { $0.url?.path } == ["/session/ses_correct/prompt_async"])
        #expect(runtime.ledger?.record(id: id)?.delivery.meta["opencode_destination_validated"] == "true")
    }

    @Test(arguments: [false, true])
    func pollingDuringNativePreflightPreventsAPostAndReportsDelivered(_ agentAlreadyReplied: Bool) async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let http = NativeOpenCodeHTTP(); await http.pause()
        let routing = f.routing; routing.deliveryMethod = .opencode; routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        let session = connectorSession(agent: .opencode)
        routing.openCodeSessionIDs[session.sessionKey] = "ses_exact"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: routing, clock: f.clock,
                                  socketPath: f.directory.appendingPathComponent("poll-race.sock").path,
                                  ledgerURL: f.directory.appendingPathComponent("poll-race.json"),
                                  connectors: [OpenCodeConnector(transport: http, credentials: { nil })], targetIsDead: { _ in false })
        try runtime.start(); defer { runtime.stop(); Task { await http.release() } }
        runtime.registerSession(session)
        let send = Task { await runtime.sendUserMessage("Poll race") }
        try await eventually { runtime.sends.count == 1 }
        let poll = await runtime.callTool("zeus_get_responses", arguments: [:], sessionKey: session.sessionKey)
        #expect(poll.structured?["items"]?[0]?["text"] == "Poll race")
        if agentAlreadyReplied { _ = await runtime.callTool("zeus_say", arguments: ["text": "Done"], sessionKey: session.sessionKey) }
        await http.release()
        #expect(await send.value == .delivered)
        #expect(await http.calls.allSatisfy { $0.httpMethod != "POST" })
        if agentAlreadyReplied { #expect(runtime.assistantActivity == nil) }
        else { #expect(runtime.assistantActivity?.phase == .thinking) }
    }

}
