import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

actor PromptProofRunner: ProcessRunning {
    let base: any ProcessRunning
    var keys: [[String]] = []
    init(base: any ProcessRunning) { self.base = base }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input, environment: [:])
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        guard let socket = arguments.firstIndex(of: "-S"), arguments[socket + 1].contains("/zl3_") else { throw ConnectorError.missingTmuxSocket }
        let result = try await base.run(executable: executable, arguments: arguments, input: input, environment: environment)
        if result.status == 0, arguments.contains("send-keys"), let target = arguments.firstIndex(of: "-t") {
            keys.append(Array(arguments.dropFirst(target + 2)))
        }
        return result
    }
}

/// Real installed CLIs, runtime, controller and bridge; all models/profiles/panes are disposable.
@MainActor
struct LiveManagedPromptAnswerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_PROMPT_MODEL_URL"] != nil), .timeLimit(.minutes(2)),
          arguments: [AgentKind.claude, .codex, .opencode])
    func clickedChoiceProceedsAndQueuedComposeFlows(agent: AgentKind) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["ZEUS_PROMPT_MODEL_URL"].flatMap(URL.init(string:)))
        try #require(base.host == "127.0.0.1")
        let root = URL(fileURLWithPath: "/tmp/zl3_" + UUID().uuidString.prefix(8))
        let home = root.appendingPathComponent("home"), folder = root.appendingPathComponent("home/project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let executables = ManagedExecutables.detect(), runner = FoundationProcessRunner()
        let tmux = try #require(executables.tmux), executable = try #require(executables.agents[agent])
        defer {
            let process = Process(); process.executableURL = tmux; process.arguments = ["-S", socket, "kill-server"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try? process.run(); process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "CODEX_HOME": home.appendingPathComponent(".codex").path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path, "ANTHROPIC_BASE_URL": base.absoluteString,
            "ANTHROPIC_API_KEY": "p1-local-fixture", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false"]
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME"] {
            try FileManager.default.createDirectory(atPath: environment[key] ?? home.path, withIntermediateDirectories: true)
        }
        if agent == .claude {
            let profile = try JSONSerialization.data(withJSONObject: ["hasCompletedOnboarding": true, "theme": "dark", "hasAcknowledgedCostThreshold": true])
            try profile.write(to: home.appendingPathComponent(".claude.json"))
            try profile.write(to: home.appendingPathComponent(".claude/.claude.json"))
            try JSONSerialization.data(withJSONObject: ["permissions": ["ask": ["Bash"]]])
                .write(to: home.appendingPathComponent(".claude/settings.json"))
        }
        if agent == .opencode {
            environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache").path
            environment["XDG_STATE_HOME"] = home.appendingPathComponent(".local/state").path
        }
        let version = try await runner.run(executable: executable, arguments: ["--version"], input: nil, environment: environment)
        let versionText = String(decoding: version.stdout, as: UTF8.self)
        #expect(version.status == 0 && !versionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("P1 real CLI \(agent.rawValue): \(versionText.trimmingCharacters(in: .whitespacesAndNewlines))")
        let launchRunner: any ProcessRunning
        switch agent {
        case .codex: launchRunner = LiveCodexModelRunner(base: base, project: folder.path)
        case .opencode: launchRunner = LiveOpenCodeModelRunner(base: base, project: folder.path)
        default: launchRunner = runner
        }
        let proof = PromptProofRunner(base: launchRunner)
        let clock = TestRuntimeClock(), routing = FakeRouting()
        routing.managedSession = .init(enabled: true, folder: folder.path, agent: agent, launchPrompt: "Use Zeus for messages.", startWhenZeusOpens: true)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables, hosting: ManagedTmux(executable: tmux, runner: proof, environment: environment, testSocket: socket),
            environment: environment, clock: clock, terminalOpener: FakeManagedTerminal(), isolatedSocket: socket)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector()], managedController: controller)
        try runtime.start(); defer { runtime.stop() }
        let end = ContinuousClock.now + .seconds(60)
        clock.advance(10, wake: false)
        while runtime.managedStatus != .running(.idle) || runtime.sessions.isEmpty {
            guard ContinuousClock.now < end else { throw ManagedSessionError.command("P1 startup \(agent): \(runtime.managedStatus)") }
            if !controller.isBusy, let pane = controller.record?.pane {
                let screen = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
                let plain = screen?.plainLines.joined(separator: "\n") ?? ""
                // Fixture human accepts only the scratch folder/fake API key, never a tool prompt.
                if plain.contains("Quick safety check:") && plain.contains("Yes, I trust this folder") {
                    _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Down", "Enter"], input: nil)
                } else if plain.contains("Do you want to use this API key?") {
                    _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Up", "Enter"], input: nil)
                }
                controller.refresh()
            }
            clock.advance(1, wake: false); try await Task.sleep(for: .milliseconds(200))
        }
        let trigger = "P1_PERMISSION_\(agent.rawValue)_" + UUID().uuidString
        #expect(await runtime.sendUserMessage(trigger, deliveryID: "d_p1_prompt") == .delivered)
        let blockedEnd = ContinuousClock.now + .seconds(30)
        while runtime.managedPrompt?.options.isEmpty != false {
            guard ContinuousClock.now < blockedEnd else {
                let screen = try await controller.hosting?.capture(try #require(controller.record?.pane), owner: controller.record?.owner ?? "")
                throw ManagedSessionError.command("P1 no options: \(runtime.managedStatus) \(String(describing: screen))")
            }
            if !controller.isBusy { controller.refresh(); clock.advance(3, wake: false) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let prompt = try #require(runtime.managedPrompt), pane = try #require(controller.record?.pane)
        var evidence = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { evidence.deleteLastPathComponent() }
        let captured = try #require(try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? ""))
        try Data(captured.screen.utf8).write(to: evidence.appendingPathComponent("build/p1-seam-\(agent.rawValue).ansi"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("p1-approval.txt").path))
        #expect(await proof.keys.isEmpty, "No controller/timer may answer before a click")
        _ = await runtime.sendUserMessage("P1 queued compose after approval.", deliveryID: "d_p1_later")
        #expect(runtime.ledger?.record(id: "d_p1_later")?.delivery.attempts == 0)
        if agent == .opencode {
            // Move the Terminal highlight to Reject. The user clicks Allow once;
            // the backend must verify each Left, then confirm only Allow once.
            _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Right", "Right"], input: nil)
            let changedEnd = ContinuousClock.now + .seconds(3)
            while true {
                let now = try #require(try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? ""))
                if ManagedPromptParser.parse(now, agent: agent, scope: controller.promptScope)?.highlightedOption == 2 { break }
                guard ContinuousClock.now < changedEnd else { throw ManagedSessionError.command("OpenCode highlight didn't move") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let id = agent == .claude ? "1" : agent == .codex ? "y" : "once"
        let option = try #require(prompt.options.first { $0.id == id })
        #expect(await runtime.answerManagedPrompt(fingerprint: prompt.fingerprint, optionID: id) == .answered(optionID: id, label: option.label))
        #expect(await proof.keys == (agent == .claude ? [["1"]] : agent == .codex ? [["y"]] : [["Left"], ["Left"], ["Enter"]]))
        let proceedEnd = ContinuousClock.now + .seconds(20)
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("p1-approval.txt").path)
            || runtime.ledger?.record(id: "d_p1_later")?.transportDeliveredAt == nil {
            guard ContinuousClock.now < proceedEnd else { throw ManagedSessionError.command("Agent didn't proceed/unblock queued input: \(runtime.managedStatus)") }
            if !controller.isBusy { controller.refresh(); clock.advance(1, wake: true) }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try String(contentsOf: folder.appendingPathComponent("p1-approval.txt"), encoding: .utf8) == "P1_PROCEEDED")
        #expect(cards.cards.contains { $0.status == .answered && $0.body.hasSuffix("You chose \(option.label).") })
        #expect(runtime.ledger?.records.count == 2, "A local consent choice is not an MCP answer/delivery")
    }
}
