import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Adds only localhost model overrides to a production managed launch in a
/// disposable socket. Production MCP injection and permission argv stay intact.
struct LiveOpenCodeModelRunner: ProcessRunning {
    let base: URL
    let project: String
    let runner = FoundationProcessRunner()
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input, environment: [:])
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        var args = arguments
        if args.contains("respawn-pane"), let configIndex = args.firstIndex(where: { $0.hasPrefix("OPENCODE_CONFIG_CONTENT=") }) {
            guard let index = args.firstIndex(of: "-S"), args[index + 1].contains("/zl3_"), base.host == "127.0.0.1" else { throw ConnectorError.invalidURL }
            let raw = String(args[configIndex].dropFirst("OPENCODE_CONFIG_CONTENT=".count))
            var config = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            config["autoupdate"] = false; config["share"] = "disabled"
            config["model"] = "openai/gpt-4.1-mini"; config["enabled_providers"] = ["openai"]
            config["provider"] = ["openai": ["options": ["baseURL": base.absoluteString + "/v1", "apiKey": "l3-local-fixture"]]]
            args[configIndex] = "OPENCODE_CONFIG_CONTENT=" + String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
            args.insert(contentsOf: ["XDG_CACHE_HOME=" + project + "/../home/.cache", "XDG_STATE_HOME=" + project + "/../home/.local/state",
                "OPENCODE_DISABLE_AUTOUPDATE=true", "OPENCODE_DISABLE_EXTERNAL_PLUGINS=true", "OPENCODE_DISABLE_MODELS_FETCH=true", "OPENCODE_DISABLE_LSP_DOWNLOAD=true"], at: configIndex)
        }
        return try await runner.run(executable: executable, arguments: args, input: input, environment: environment)
    }
}

@MainActor
struct LiveOpenCodeDeliveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_LIVE_OPENCODE_BASE_URL"] != nil), .timeLimit(.minutes(2)))
    func realOpenCodeSubmitsWrappedComposeAndCallsBothZeusTools() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["ZEUS_LIVE_OPENCODE_BASE_URL"].flatMap(URL.init(string:)))
        try #require(base.host == "127.0.0.1")
        let executables = ManagedExecutables.detect()
        let tmux = try #require(executables.tmux)
        let opencode = try #require(executables.agents[.opencode])
        let runner = FoundationProcessRunner()
        let root = URL(fileURLWithPath: "/tmp/zl3_" + UUID().uuidString.prefix(8))
        let home = root.appendingPathComponent("home"), project = root.appendingPathComponent("home/project")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        defer {
            let p = Process(); p.executableURL = tmux; p.arguments = ["-S", socket, "kill-server"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let version = try await runner.run(executable: opencode, arguments: ["--version"], input: nil,
            environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path, "PATH": "/usr/bin:/bin"])
        #expect(String(decoding: version.stdout, as: UTF8.self).contains("1.18.31"))
        let routing = FakeRouting(), clock = TestRuntimeClock()
        routing.managedSession = .init(enabled: true, folder: project.path, agent: .opencode, launchPrompt: "Reply through Zeus.", startWhenZeusOpens: true)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables,
            hosting: ManagedTmux(executable: tmux, runner: LiveOpenCodeModelRunner(base: base, project: project.path),
                environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path, "PATH": "/usr/bin:/bin"], testSocket: socket),
            environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path, "PATH": "/usr/bin:/bin"],
            clock: clock, terminalOpener: FakeManagedTerminal(), isolatedSocket: socket)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector()], managedController: controller)
        try runtime.start(); defer { runtime.stop() }
        let deadline = ContinuousClock.now + .seconds(60)
        while runtime.managedStatus != .running(.idle) || runtime.sessions.isEmpty {
            guard ContinuousClock.now < deadline else { throw ManagedSessionError.command("OpenCode startup: \(runtime.managedStatus)") }
            if !controller.isBusy { controller.refresh(); clock.advance(1, wake: false) }
            try await Task.sleep(for: .milliseconds(200))
        }
        let pane = try #require(controller.record?.pane)
        let dimensions = try await runner.run(executable: tmux, arguments: ["-S", socket, "display-message", "-p", "-t", pane.id, "#{pane_width}x#{pane_height}"], input: nil)
        #expect(String(decoding: dimensions.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) == "120x40")
        let conversation = ConversationModel(cards: cards, messaging: runtime, clock: { clock.now })
        conversation.draft = "OpenCode live test: reply through Zeus with the word PEACH and the name of this folder."
        let result = await conversation.send()
        guard case .message(_, .delivered)? = result else {
            let snapshot = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
            throw ManagedSessionError.command("OpenCode compose: \(String(describing: result)); \(String(describing: snapshot)); ledger: \(String(describing: runtime.ledger?.records))")
        }
        let end = ContinuousClock.now + .seconds(30)
        while runtime.ledger?.records.first?.delivery.ackedAt == nil || !cards.cards.contains(where: { $0.body == "Live OpenCode received the complete wrapped compose message." }) {
            guard ContinuousClock.now < end else {
                let snapshot = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
                throw ManagedSessionError.command("OpenCode submitted but no real ack: \(String(describing: snapshot))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(runtime.ledger?.records.first?.delivery.attempts == 1)
        #expect(cards.cards.contains { $0.body == "Live OpenCode received the complete wrapped compose message." })
        #expect(conversation.draft.isEmpty)
    }
}
