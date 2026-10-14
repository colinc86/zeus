import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private struct CY1NoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}

private struct CY1ScopedRunner: ProcessRunning {
    let socket: String
    let home: URL
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard socket.contains("/zcy1_"), let index = arguments.firstIndex(of: "-S"),
              arguments.indices.contains(index + 1), arguments[index + 1] == socket else { throw ConnectorError.missingTmuxSocket }
        return try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input,
            environment: ["HOME": home.path, "TMUX_TMPDIR": home.appendingPathComponent("tmux").path,
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"])
    }
}

/// Real, separately configured agents: no managed launch/adoption and no user profile.
@Suite(.serialized) @MainActor struct ConnectOwnLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_CY1_LIVE"] == "1"), .timeLimit(.minutes(3)), arguments: [AgentKind.claude, .codex, .opencode].filter {
        guard let selected = ProcessInfo.processInfo.environment["ZEUS_CY1_AGENTS"] else { return true }
        return selected.split(separator: ",").contains(Substring($0.rawValue))
    })
    func sessionPickerComposerAndRealBridgeReply(agent: AgentKind) async throws {
        let executables = ManagedExecutables.detect()
        let tmux = try #require(executables.tmux), cli = try #require(executables.agents[agent])
        let root = URL(fileURLWithPath: "/private/tmp/zcy1_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home"), folder = root.appendingPathComponent("project")
        let socket = root.appendingPathComponent("tmux.sock").path
        let bridgeSocket = root.appendingPathComponent("bridge.sock").path
        let suite = "zeus-cy1-live-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: CY1NoCredentials())
        settings.managedSession = .init(enabled: false, folder: "", agent: agent, launchPrompt: "", startWhenZeusOpens: false)
        settings.backend = try #require(AssistantBackend(rawValue: agent.rawValue))
        settings.deliveryMethod = agent == .opencode ? .opencode : .tmux
        let runner = CY1ScopedRunner(socket: socket, home: home)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let controller = ManagedSessionController(configuration: { settings.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: bridgeSocket,
            executables: executables, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], isolatedSocket: socket)
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: settings,
            socketPath: bridgeSocket, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [ChannelDeliveryConnector(), TmuxConnector(executable: tmux, runner: runner), OpenCodeConnector()], managedController: controller)
        let process = Process(), logURL = root.appendingPathComponent("fixture.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            runtime.stop()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? log.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try runtime.start()
        let python = try #require(["/opt/homebrew/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) })
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("CY1LocalModel.py").path,
            "--root", root.path, "--agent", agent.rawValue, "--tmux", tmux.path, "--cli", cli.path,
            "--bridge", Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp").path, "--bridge-socket", bridgeSocket]
        process.environment = ["HOME": root.path, "PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = ContinuousClock.now + .seconds(80)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) {
            guard process.isRunning, ContinuousClock.now < deadline else {
                throw ManagedSessionError.command("CY1 fixture startup: " + (try String(contentsOf: logURL, encoding: .utf8)))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        var lastScreen = ""
        func capture() async throws -> TmuxInputSnapshot? {
            let screen = try await runner.run(executable: tmux, arguments: ["-u", "-S", socket, "capture-pane", "-p", "-e", "-t", "%0"], input: nil)
            let metadata = try await runner.run(executable: tmux, arguments: ["-u", "-S", socket, "display-message", "-p", "-t", "%0", "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}|#{bracket_paste_flag}"], input: nil)
            lastScreen = String(decoding: screen.stdout, as: UTF8.self)
            return TmuxInputSnapshot(metadata: metadata.stdout, screen: screen.stdout)
        }
        while true {
            let snapshot = try await capture()
            let plain = ManagedPaneSnapshot(screen: lastScreen, inputMetadata: "").plainLines.joined(separator: "\n")
            // Explicit fixture-human consent: only its disposable trust, synthetic
            // key and requested Zeus development channel, never tool prompts.
            if agent == .claude, plain.contains("Quick safety check:"), plain.contains("Yes, I trust this folder"), plain.contains(folder.path) {
                _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", "%0", "Down", "Enter"], input: nil)
            } else if agent == .claude, plain.contains("Do you want to use this API key?") {
                _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", "%0", "Up", "Enter"], input: nil)
            } else if agent == .claude, plain.contains("WARNING: Loading development channels"), plain.contains("I am using this for local development") {
                _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", "%0", "1", "Enter"], input: nil)
            }
            if !runtime.sessions.isEmpty, snapshot?.isEmpty == true,
               plain.contains("CY1_READY"), !plain.lowercased().contains("esc interrupt") { break }
            guard process.isRunning, ContinuousClock.now < deadline else {
                throw ManagedSessionError.command("CY1 \(agent) startup: \(runtime.sessions.count) bridge(s)\n" + plain.replacingOccurrences(of: root.path, with: "/FIXTURE"))
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let session = try #require(runtime.sessions.first { $0.agent == agent && $0.cwd == folder.path })
        #expect(AssistantSessionPicker.choices(settings: settings, sessions: runtime.sessions).contains { $0.id == session.sessionKey })
        settings.assistantSessionKey = session.sessionKey // The picker's exact persisted binding.
        #expect(runtime.assistantTarget == session.sessionKey && !controller.enabled && controller.record == nil)
        if agent != .opencode {
            AgentSettingsView.selectPane(session.tmuxPane, panes: [], socketPath: socket, settings: settings)
            #expect(settings.tmuxTarget == session.tmuxPane && settings.tmuxTargetSocketPath == AppSettings.normalizedTmuxSocket(socket),
                "Hello pane \(session.tmuxPane ?? "nil"), socket \(session.tmuxSocketPath ?? "nil"); saved \(settings.tmuxTargetSocketPath ?? "nil")")
        }
        if agent == .opencode {
            let ready = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: root.appendingPathComponent("ready.json")))
            guard case .string(let endpoint)? = ready["openCodeURL"] else { throw ConnectorError.invalidURL }
            settings.openCodeURLText = endpoint
            let discovery = OpenCodeSessionDiscovery()
            await discovery.refresh(baseURL: settings.openCodeBaseURL, directory: folder.path, password: nil)
            #expect(discovery.error == nil)
            try #require(discovery.sessions.count == 1, "Select the fixture's exact native conversation, never newest by default")
            let native = try #require(discovery.sessions.first)
            #expect(OpenCodeSessionPicker.select(native.id, for: session.sessionKey, sessions: discovery.sessions, endpoint: discovery.listedBaseURL, settings: settings))
        }
        let conversation = ConversationModel(cards: cards, messaging: runtime)
        conversation.draft = "CY1_COMPOSE_PROBE: Please reply with zeus_say."
        let outcome = await conversation.send()
        guard case .message(_, .delivered)? = outcome else {
            _ = try await capture()
            throw ManagedSessionError.command("CY1 \(agent) compose: \(String(describing: outcome))\n" + lastScreen.replacingOccurrences(of: root.path, with: "/FIXTURE"))
        }
        let expected = "CY1 \(agent.rawValue) received the composer message through Connect your own."
        let replyDeadline = ContinuousClock.now + .seconds(30)
        while !cards.cards.contains(where: { $0.body == expected }) {
            guard ContinuousClock.now < replyDeadline else {
                _ = try await capture()
                throw ManagedSessionError.command("CY1 \(agent) no bridge reply\n" + lastScreen.replacingOccurrences(of: root.path, with: "/FIXTURE"))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(conversation.draft.isEmpty)
        #expect(conversation.thread.contains { $0.body == expected })
        #expect(cards.cards.first { $0.body == expected }?.sessionKey == session.sessionKey)
        let requests = try String(contentsOf: root.appendingPathComponent("requests.ndjson"), encoding: .utf8)
        #expect(requests.contains("CY1_COMPOSE_PROBE"), "The real CLI sent the composer input to its model")
        #expect(runtime.ledger?.records.first?.delivery.sessionKey == session.sessionKey)
        if agent == .codex {
            let saved = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
            #expect(!saved.contains("TMUX"), "Namespace pass-through must remain launch-only, not save an old pane")
        }
        if ProcessInfo.processInfo.environment["ZEUS_CY1_RECORD_FIXTURES"] == "1" || ProcessInfo.processInfo.environment["ZEUS_CY1_EVIDENCE_DIR"] != nil {
            _ = try await capture()
            var worktree = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { worktree.deleteLastPathComponent() }
            let evidence = ProcessInfo.processInfo.environment["ZEUS_CY1_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? worktree.appendingPathComponent("TestFixtures/live/cy1")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            func scrub(_ value: String) -> String {
                value.replacingOccurrences(of: root.path, with: "/FIXTURE")
                    .replacingOccurrences(of: cli.path, with: "/CLI/" + agent.rawValue)
                    .replacingOccurrences(of: Bundle.main.bundleURL.path, with: "/BUNDLE/Zeus.app")
            }
            try Data(scrub(lastScreen).utf8).write(to: evidence.appendingPathComponent(agent.rawValue + ".ansi"))
            let version = try await FoundationProcessRunner().run(executable: cli, arguments: ["--version"], input: nil,
                environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path, "PATH": "/opt/homebrew/bin:/usr/bin:/bin"])
            let facts: [String: JSONValue] = ["agent": .string(agent.rawValue), "version": .string(String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)),
                "managed_enabled": .bool(controller.enabled), "composer_delivered": .bool(true), "model_received_compose": .bool(requests.contains("CY1_COMPOSE_PROBE")),
                "real_bridge_reply_in_thread": .bool(true), "selected_session": .string(scrub(session.sessionKey)), "delivery_method": .string(settings.deliveryMethod.rawValue)]
            try JSONEncoder().encode(facts).write(to: evidence.appendingPathComponent(agent.rawValue + ".json"))
            for file in ["launch.json", "registration.json"] where FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) {
                try Data(scrub(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)).utf8).write(to: evidence.appendingPathComponent(agent.rawValue + "-" + file))
            }
            if ProcessInfo.processInfo.environment["ZEUS_CY1_RECORD_FIXTURES"] == "1", ProcessInfo.processInfo.environment["ZEUS_CY1_EVIDENCE_DIR"] != nil {
                let fixtures = worktree.appendingPathComponent("TestFixtures/live/cy1")
                try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
                for file in try FileManager.default.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(agent.rawValue) {
                    try Data(contentsOf: file).write(to: fixtures.appendingPathComponent(file.lastPathComponent))
                }
            }
        }
    }
}
