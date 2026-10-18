import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Adds only localhost model overrides to a production managed launch in a
/// disposable socket. Production MCP injection and permission argv stay intact.
struct LiveCodexModelRunner: ProcessRunning {
    let base: URL
    let project: String
    let runner = FoundationProcessRunner()
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input, environment: [:])
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        var args = arguments
        if args.contains("respawn-pane"), args.contains("--no-daemon") {
            guard let index = args.firstIndex(of: "-S"), args[index + 1].contains("/zl3_"), base.host == "127.0.0.1" else { throw ConnectorError.invalidURL }
            let encode = { (s: String) throws in String(decoding: try JSONEncoder().encode(s), as: UTF8.self) }
            let overrides = ["check_for_update_on_startup=false", "model=\"l3\"", "model_provider=\"l3\"",
                "model_providers.l3={name=\"L3 localhost fixture\",base_url=\"\(base.absoluteString)/v1\",wire_api=\"responses\",requires_openai_auth=false}",
                "projects.\(try encode(project)).trust_level=\"trusted\""]
            args.insert(contentsOf: overrides.flatMap { ["-c", $0] }, at: args.count - 1)
        }
        return try await runner.run(executable: executable, arguments: args, input: input, environment: environment)
    }
}

/// Reproduce the managed monitor sampling Codex between paste and Enter. Every
/// command is restricted to the disposable namespace owned by this live test.
actor LiveCodexReadinessRunner: ProcessRunning {
    let afterPaste: @MainActor @Sendable () async throws -> Void
    let evidence: URL
    let runner = FoundationProcessRunner()
    private var text = ""
    init(evidence: URL, afterPaste: @escaping @MainActor @Sendable () async throws -> Void) {
        self.evidence = evidence; self.afterPaste = afterPaste
    }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let index = arguments.firstIndex(of: "-S"), arguments[index + 1].contains("/zl3_") else { throw ConnectorError.missingTmuxSocket }
        let result = try await runner.run(executable: executable, arguments: arguments, input: input)
        if arguments.contains("load-buffer"), let input { text = String(decoding: input, as: UTF8.self) }
        if arguments.contains("paste-buffer"), result.status == 0 {
            let targetIndex = try #require(arguments.firstIndex(of: "-t"))
            let namespace = ["-u", "-S", arguments[index + 1]], target = arguments[targetIndex + 1]
            let deadline = ContinuousClock.now + .seconds(5)
            while true {
                let metadata = try await runner.run(executable: executable, arguments: namespace + ["display-message", "-p", "-t", target, "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}"], input: nil)
                let screen = try await runner.run(executable: executable, arguments: namespace + ["capture-pane", "-p", "-e", "-t", target], input: nil)
                if let snapshot = TmuxInputSnapshot(metadata: metadata.stdout, screen: screen.stdout), snapshot.containsOnlyCodexPaste(text) {
                    try screen.stdout.write(to: evidence)
                    #expect(snapshot.lines.suffix(4).contains { $0.contains("⚠") && $0.contains("warning") && $0.contains("f2 to view") })
                    #expect(!snapshot.lines.suffix(4).contains { $0.contains("? for shortcuts") })
                    break
                }
                guard ContinuousClock.now < deadline else { throw ManagedSessionError.command("Live warning composer did not render") }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await afterPaste()
        }
        return result
    }
}

@MainActor
struct LiveCodexDeliveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_LIVE_CODEX_BASE_URL"] != nil), .timeLimit(.minutes(2)), arguments: [false, true])
    func realCodexSubmitsWrappedComposeAndCallsBothZeusTools(warning: Bool) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["ZEUS_LIVE_CODEX_BASE_URL"].flatMap(URL.init(string:)))
        try #require(base.host == "127.0.0.1")
        let executables = ManagedExecutables.detect()
        let tmux = try #require(executables.tmux)
        let codex = try #require(executables.agents[.codex])
        let runner = FoundationProcessRunner()
        let root = URL(fileURLWithPath: "/tmp/zl3_" + UUID().uuidString.prefix(8))
        let home = root.appendingPathComponent("home"), project = root.appendingPathComponent("home/project")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        if warning {
            // A launch-local MCP startup failure produces a real warning footer.
            // It cannot access another process, profile, server or credential.
            try Data("[mcp_servers.l4_private_warning]\ncommand = \"/usr/bin/false\"\n".utf8)
                .write(to: home.appendingPathComponent(".codex/config.toml"))
        }
        let socket = root.appendingPathComponent("tmux.sock").path
        defer {
            let p = Process(); p.executableURL = tmux; p.arguments = ["-S", socket, "kill-server"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let version = try await runner.run(executable: codex, arguments: ["--version"], input: nil,
            environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path, "PATH": "/usr/bin:/bin"])
        #expect(String(decoding: version.stdout, as: UTF8.self).contains("0.162.1"))
        let routing = FakeRouting(), clock = TestRuntimeClock()
        routing.managedSession = .init(enabled: true, folder: project.path, agent: .codex, launchPrompt: "Reply through Zeus.", startWhenZeusOpens: true)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables,
            hosting: ManagedTmux(executable: tmux, runner: LiveCodexModelRunner(base: base, project: project.path),
                environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path, "PATH": "/usr/bin:/bin"], testSocket: socket),
            environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path, "PATH": "/usr/bin:/bin"],
            clock: clock, terminalOpener: FakeManagedTerminal(), isolatedSocket: socket)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        var evidenceRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { evidenceRoot.deleteLastPathComponent() }
        let readinessRunner = LiveCodexReadinessRunner(evidence: evidenceRoot.appendingPathComponent("build/l4-codex-warning-pasted.ansi")) {
            let end = ContinuousClock.now + .seconds(10)
            while controller.isBusy {
                guard ContinuousClock.now < end else { throw ManagedSessionError.command("Before-paste monitor did not settle") }
                try await Task.sleep(for: .milliseconds(20))
            }
            controller.refresh()
            while controller.isBusy {
                guard ContinuousClock.now < end else { throw ManagedSessionError.command("After-paste monitor did not settle") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(runner: warning ? readinessRunner : runner)], managedController: controller)
        try runtime.start(); defer { runtime.stop() }
        let deadline = ContinuousClock.now + .seconds(60)
        while runtime.managedStatus != .running(.idle) || runtime.sessions.isEmpty {
            guard ContinuousClock.now < deadline else { throw ManagedSessionError.command("Codex startup: \(runtime.managedStatus)") }
            if !controller.isBusy { controller.refresh(); clock.advance(1, wake: false) }
            try await Task.sleep(for: .milliseconds(200))
        }
        let pane = try #require(controller.record?.pane)
        let dimensions = try await runner.run(executable: tmux, arguments: ["-S", socket, "display-message", "-p", "-t", pane.id, "#{pane_width}x#{pane_height}"], input: nil)
        #expect(String(decoding: dimensions.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) == "120x40")
        let conversation = ConversationModel(cards: cards, messaging: runtime, clock: { clock.now })
        conversation.draft = warning
            ? "Codex live test 2: reply through Zeus with the word GUAVA and the name of this folder."
            : "Codex live test: reply through Zeus with the word KIWI and the name of this folder."
        let result = await conversation.send()
        guard case .message(_, .delivered)? = result else {
            let snapshot = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
            throw ManagedSessionError.command("Codex compose: \(String(describing: result)); \(String(describing: snapshot)); ledger: \(String(describing: runtime.ledger?.records))")
        }
        let end = ContinuousClock.now + .seconds(30)
        while runtime.ledger?.records.first?.delivery.ackedAt == nil || !cards.cards.contains(where: { $0.body == "Live Codex received the complete wrapped compose message." }) {
            guard ContinuousClock.now < end else {
                let snapshot = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
                throw ManagedSessionError.command("Codex submitted but no real ack: \(String(describing: snapshot))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(runtime.ledger?.records.first?.delivery.attempts == 1)
        #expect(cards.cards.contains { $0.body == "Live Codex received the complete wrapped compose message." })
        #expect(conversation.draft.isEmpty)
    }
}

struct LiveCodexPasteTests {
    @Test func pmWrappedComposerAndRepaintMatchButEditsDoNot() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let screen = try String(contentsOf: root.appendingPathComponent("TestFixtures/live/m6-codex-unsubmitted-pane.ansi"), encoding: .utf8)
        let text = "[zeus delivery_id=d_55c1dde2] Message from the user: Codex live test: reply through Zeus with the word KIWI and the name of this folder. (call zeus_ack with this delivery_id)"
        func value(_ s: String, x: Int = 60, y: Int = 36) throws -> TmuxInputSnapshot {
            try #require(TmuxInputSnapshot(metadata: Data("\(x)|\(y)|120|0|1".utf8), screen: Data(s.utf8)))
        }
        let live = try value(screen)
        #expect(live.containsOnlyCodexPaste(text))
        #expect(try value(screen, x: 2, y: 35).containsOnlyCodexPaste(text))
        #expect(try value(screen.replacingOccurrences(of: "1 warning", with: "2 warnings")).containsOnlyCodexPaste(text))
        #expect(!live.containsOnlyCodexPaste(text + " edited"))
        #expect(try !value(screen.replacingOccurrences(of: "delivery_id)", with: "delivery_id)x")).containsOnlyCodexPaste(text))
        #expect(try !value(screen.replacingOccurrences(of: "KIWI and", with: "KIWI\u{00a0}and")).containsOnlyCodexPaste(text))
    }
}
