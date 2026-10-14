import Foundation
import Testing
import ZeusLink
import ZeusProtocol
@testable import Zeus

struct RecordedProcess: Sendable {
    var executable: URL
    var arguments: [String]
    var input: Data?
}
actor FakeProcessRunner: ProcessRunning {
    var calls: [RecordedProcess] = []
    var rawCalls: [RecordedProcess] = []
    var failureAt: Int?
    var pauseNext = false
    var buffer = Data()
    var screen = ""
    var failCommand: String?
    var afterPaste: String = ""
    var paused: CheckedContinuation<Void, Never>?
    func setScreen(_ value: String) { screen = value }
    func appendAfterPaste(_ value: String) { afterPaste = value }
    func pause() { pauseNext = true }
    func release() { paused?.resume(); paused = nil }
    func fail(at index: Int) { failureAt = index }
    func fail(command: String) { failCommand = command }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        rawCalls.append(.init(executable: executable, arguments: arguments, input: input))
        var arguments = Array(arguments.drop(while: { $0 == "-u" }))
        if arguments.first == "-S" { arguments = Array(arguments.dropFirst(2)) }
        calls.append(.init(executable: executable, arguments: arguments, input: input))
        if pauseNext { pauseNext = false; await withCheckedContinuation { paused = $0 } }
        if calls.count == failureAt || arguments.first == failCommand { return .init(status: 1) }
        switch arguments.first {
        case "display-message": return .init(status: 0, stdout: Data("\(screen.count)|0|10000|0|1\n".utf8))
        case "capture-pane": return .init(status: 0, stdout: Data(screen.utf8))
        case "load-buffer": buffer = input ?? Data()
        case "paste-buffer": screen = String(decoding: buffer, as: UTF8.self) + afterPaste
        case "send-keys": screen = ""
        default: break
        }
        return .init(status: 0)
    }
}
actor FakeHTTPTransport: ConnectorHTTPTransport {
    var calls: [URLRequest] = []
    var results: [ConnectorHTTPResult]
    var pauseNext = false
    var paused: CheckedContinuation<Void, Never>?
    func pause() { pauseNext = true }
    func release() { paused?.resume(); paused = nil }
    init(results: [ConnectorHTTPResult] = []) { self.results = results }
    func send(_ request: URLRequest) async throws -> ConnectorHTTPResult {
        calls.append(request)
        if pauseNext { pauseNext = false; await withCheckedContinuation { paused = $0 } }
        return results.isEmpty ? .init(status: 200, body: Data("true".utf8)) : results.removeFirst()
    }
}
@MainActor
func connectorSession(agent: AgentKind = .codex, pane: String? = nil, cwd: String = "/assistant", socket: String? = "/test/tmux.sock") -> ConnectedSession {
    .init(id: UUID(), sessionKey: agent.rawValue + ":" + cwd, agent: agent, cwd: cwd, clientName: "Test",
          supportsChannel: false, tmuxPane: pane, connectedAt: Date(), tmuxSocketPath: socket)
}

@MainActor
private final class PasswordSetting { var value = "initial" }

@MainActor
struct ConnectorTests {
    @Test(arguments: [nil, "/test/other.sock", "relative.sock"] as [String?])
    func unverifiedOrMismatchedConfiguredPaneNeverStartsIO(socket: String?) async throws {
        let runner = FakeProcessRunner(), routing = FakeRouting()
        routing.deliveryMethod = .tmux; routing.tmuxTarget = "%0"; routing.tmuxTargetSocketPath = socket
        let session = connectorSession(pane: "%0")
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        await #expect(throws: ConnectorError.mismatchedTmuxSocket) {
            try await connector.deliver(.init(kind: .userMessage, sessionKey: session.sessionKey, content: "Hold"), to: session, bridge: nil, routing: routing)
        }
        #expect(await runner.rawCalls.isEmpty)
        #expect(ConnectorError.mismatchedTmuxSocket.postponesDelivery)
    }

    @Test func explicitNamespaceMatchesAndOriginRepliesIgnoreAssistantOverrideNamespace() async throws {
        let runner = FakeProcessRunner(), routing = FakeRouting()
        routing.deliveryMethod = .tmux; routing.assistantSessionKey = "codex:/different"
        routing.tmuxTarget = "%0"; routing.tmuxTargetSocketPath = "/test/other.sock"
        let session = connectorSession(pane: "%9")
        let context = DeliveryRoutingContext(settings: routing, assistantSessionKey: routing.assistantSessionKey, tmuxSocketPath: session.tmuxSocketPath)
        try await TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
            .deliver(.init(kind: .reply, sessionKey: session.sessionKey, content: "Origin"), to: session, bridge: nil, routing: context)
        #expect(await runner.rawCalls.allSatisfy { Array($0.arguments.prefix(3)) == ["-u", "-S", "/test/tmux.sock"] })
        #expect(await runner.calls.first { $0.arguments.first == "paste-buffer" }?.arguments.last == "%9")
    }

    @Test func namespaceChangeWhileSnapshotIsSuspendedPreventsPaste() async throws {
        let runner = FakeProcessRunner(), routing = FakeRouting()
        await runner.pause()
        routing.deliveryMethod = .tmux; routing.tmuxTarget = "%0"
        let session = connectorSession(pane: "%0")
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        let task = Task { try await connector.deliver(.init(kind: .userMessage, sessionKey: session.sessionKey, content: "Hold"), to: session, bridge: nil, routing: routing) }
        try await waitForProcesses(runner, count: 1)
        routing.tmuxTargetSocketPath = "/test/other.sock"
        await runner.release()
        await #expect(throws: ConnectorError.mismatchedTmuxSocket) { try await task.value }
        #expect(await runner.calls.allSatisfy { !["paste-buffer", "send-keys"].contains($0.arguments.first ?? "") })
    }

    @Test func tmuxUsesLiteralInputAndExactCommandSequence() async throws {
        let runner = FakeProcessRunner()
        let binary = URL(fileURLWithPath: "/test/tmux")
        let connector = TmuxConnector(executable: binary, runner: runner)
        let routing = FakeRouting(); routing.deliveryMethod = .tmux; routing.tmuxTarget = "%7"
        let session = connectorSession()
        let delivery = Delivery(id: "d_12345678", kind: .reply, cardID: "c_abcdefgh", sessionKey: session.sessionKey,
                                content: "Reply: No\n\t; $(touch /tmp/never-run) `date`")
        #expect(connector.canDeliver(to: session, bridge: nil, routing: routing))
        try await connector.deliver(delivery, to: session, bridge: nil, routing: routing)
        let calls = await runner.calls.filter { !["display-message", "capture-pane"].contains($0.arguments.first ?? "") }
        #expect(calls.map(\.executable) == [binary, binary, binary])
        #expect(await runner.rawCalls.allSatisfy { $0.arguments.first == "-u" })
        #expect(calls.map(\.arguments) == [
            ["load-buffer", "-b", "zeus-d_12345678", "-"],
            ["paste-buffer", "-p", "-d", "-b", "zeus-d_12345678", "-t", "%7"],
            ["send-keys", "-t", "%7", "Enter"]
        ])
        #expect(calls.first?.input == Data("[zeus delivery_id=d_12345678 card_id=c_abcdefgh] Reply: No ; $(touch /tmp/never-run) `date` (call zeus_ack with this delivery_id)".utf8))
        #expect(calls.dropFirst().allSatisfy { $0.input == nil })
        #expect(AgentInjectionText.format(Delivery(id: "d_12345678", kind: .userMessage, sessionKey: "s", content: "Hi")) == "[zeus delivery_id=d_12345678] Hi (call zeus_ack with this delivery_id)")
    }

    @Test func tmuxMissingPaneFailsAndCleansOnlyItsOwnBuffer() async throws {
        let runner = FakeProcessRunner(); await runner.fail(command: "paste-buffer")
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        let routing = FakeRouting(); routing.deliveryMethod = .tmux; routing.tmuxTarget = "%missing"
        let session = connectorSession()
        let delivery = Delivery(id: "d_12345678", kind: .userMessage, sessionKey: session.sessionKey, content: "Hello")
        await #expect(throws: ConnectorError.processExit(1)) { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        let calls = await runner.calls.filter { !["display-message", "capture-pane"].contains($0.arguments.first ?? "") }
        #expect(calls.count == 3)
        #expect(calls.last?.arguments == ["delete-buffer", "-b", "zeus-d_12345678"])
        #expect(!calls.contains { $0.arguments.first == "send-keys" })
    }

    @Test func tmuxConfigurationAndOriginRouting() async throws {
        let runner = FakeProcessRunner()
        let connector = TmuxConnector(executable: nil, runner: runner)
        let routing = FakeRouting()
        let session = connectorSession(pane: "%9")
        #expect(!connector.canDeliver(to: session, bridge: nil, routing: routing))
        routing.deliveryMethod = .tmux
        #expect(connector.canDeliver(to: session, bridge: nil, routing: routing))
        await #expect(throws: ConnectorError.missingTmux) {
            try await connector.deliver(.init(kind: .userMessage, sessionKey: session.sessionKey, content: "x"), to: session, bridge: nil, routing: routing)
        }
        let real = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        routing.assistantSessionKey = "codex:/another"; routing.tmuxTarget = "%assistant"
        try await real.deliver(.init(kind: .reply, sessionKey: session.sessionKey, content: "Origin reply"), to: session, bridge: nil, routing: routing)
        #expect(await runner.calls.first { $0.arguments.first == "paste-buffer" }?.arguments.last == "%9")
        #expect(!real.canDeliver(to: connectorSession(), bridge: nil, routing: routing))
        #expect(TmuxExecutable.resolve(paths: ["/not/a/tmux"]) == nil)
    }

    @Test func foundationRunnerReturnsExitAndHonorsTimeoutAndCancellation() async throws {
        let runner = FoundationProcessRunner()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], input: nil)
        #expect(result.status == 1)
        let echo = try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: Data("stdin ⚡".utf8))
        #expect(echo.stdout == Data("stdin ⚡".utf8))
        await #expect(throws: ConnectorError.processTimeout) {
            try await FoundationProcessRunner(timeout: 0.03).run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], input: nil)
        }
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], input: nil) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func concurrentTmuxDeliveriesStayInSeparatePasteSubmitTransactions() async throws {
        let runner = FakeProcessRunner(); await runner.pause()
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        let routing = FakeRouting(); routing.deliveryMethod = .tmux; routing.tmuxTarget = "%7"
        let session = connectorSession()
        let first = Task { try await connector.deliver(.init(id: "d_first001", kind: .userMessage, sessionKey: session.sessionKey, content: "First"), to: session, bridge: nil, routing: routing) }
        try await waitForProcesses(runner, count: 1)
        let second = Task { try await connector.deliver(.init(id: "d_second01", kind: .userMessage, sessionKey: session.sessionKey, content: "Second"), to: session, bridge: nil, routing: routing) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await runner.calls.count == 1)
        await runner.release()
        try await first.value; try await second.value
        let calls = await runner.calls.filter { !["display-message", "capture-pane"].contains($0.arguments.first ?? "") }
        #expect(calls.map { $0.arguments.first } == ["load-buffer", "paste-buffer", "send-keys", "load-buffer", "paste-buffer", "send-keys"])
        #expect(calls[0].arguments.contains("zeus-d_first001") && calls[3].arguments.contains("zeus-d_second01"))
    }

    @Test func cancellationWhileWaitingForPanePermitDoesNotInject() async throws {
        let runner = FakeProcessRunner(); await runner.pause()
        let connector = TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner)
        let routing = FakeRouting(); routing.deliveryMethod = .tmux; routing.tmuxTarget = "%7"
        let session = connectorSession()
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "x")
        let first = Task { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        try await waitForProcesses(runner, count: 1)
        let second = Task { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await runner.release(); try await first.value
        #expect(await runner.calls.filter { !["display-message", "capture-pane"].contains($0.arguments.first ?? "") }.count == 3)
    }

    private func waitForProcesses(_ runner: FakeProcessRunner, count: Int) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while await runner.calls.count != count {
            guard ContinuousClock.now < end else { throw RuntimeTestError.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

}
