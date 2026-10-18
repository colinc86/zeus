import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

actor LiveJournalFailureRunner: ProcessRunning {
    let runner = FoundationProcessRunner()
    var pasted = false
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let index = arguments.firstIndex(of: "-S"), arguments[index + 1].contains("/zlive_") else { throw ConnectorError.missingTmuxSocket }
        if pasted && (arguments.contains("capture-pane") || arguments.contains("display-message")) { throw ConnectorError.processTimeout }
        let result = try await runner.run(executable: executable, arguments: arguments, input: input)
        if arguments.contains("paste-buffer"), result.status == 0 {
            pasted = true
            try await Task.sleep(for: .milliseconds(100))
        }
        return result
    }
}

actor LiveJournalRecordingRunner: ProcessRunning {
    let runner = FoundationProcessRunner()
    var enters = 0, pastes = 0
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let index = arguments.firstIndex(of: "-S"), arguments[index + 1].contains("/zlive_") else { throw ConnectorError.missingTmuxSocket }
        let result = try await runner.run(executable: executable, arguments: arguments, input: input)
        if result.status == 0 {
            if arguments.contains("paste-buffer") { pastes += 1 }
            if arguments.contains("send-keys") && arguments.last == "Enter" { enters += 1 }
        }
        return result
    }
}

/// Leave a real owned paste at attempts 5, then recreate the runtime without Retry.
@MainActor
struct LiveClaudeJournalRecoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_LIVE_CLAUDE_BASE_URL"] != nil), .timeLimit(.minutes(2)))
    func exhaustedPasteRecoversOnRuntimeRelaunchAndUnblocksLaterMessage() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["ZEUS_LIVE_CLAUDE_BASE_URL"].flatMap(URL.init(string:)))
        try #require(base.host == "127.0.0.1")
        let executables = ManagedExecutables.detect()
        let tmux = try #require(executables.tmux)
        try #require(executables.agents[.claude] != nil)
        let root = URL(fileURLWithPath: "/tmp/zlive_" + UUID().uuidString.prefix(8))
        let home = root.appendingPathComponent("home"), folder = root.appendingPathComponent("home/project")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let runner = FoundationProcessRunner()
        defer {
            let process = Process(); process.executableURL = tmux; process.arguments = ["-S", socket, "kill-server"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try? process.run(); process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let profile = try JSONSerialization.data(withJSONObject: ["hasCompletedOnboarding": true, "theme": "dark", "hasAcknowledgedCostThreshold": true])
        try profile.write(to: home.appendingPathComponent(".claude.json"))
        try profile.write(to: home.appendingPathComponent(".claude/.claude.json"))
        let statusline = home.appendingPathComponent("statusline.sh")
        try Data("#!/bin/sh\ncat >/dev/null\ndate '+  Fixture status %H:%M:%S'\nprintf '  Status row 2\\n  Status row 3\\n  Status row 4\\n  Status row 5\\n  Status row 6\\n'\n".utf8).write(to: statusline)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: statusline.path)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": statusline.path, "refreshInterval": 1]])
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let routing = FakeRouting(), clock = TestRuntimeClock()
        routing.managedSession = .init(enabled: true, folder: folder.path, agent: .claude, launchPrompt: "Use Zeus for replies.", startWhenZeusOpens: true)
        let environment = ["HOME": home.path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
                "PATH": "/usr/bin:/bin", "ANTHROPIC_BASE_URL": base.absoluteString, "ANTHROPIC_API_KEY": "l-local-fixture",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false"]
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables, environment: environment,
            clock: clock, terminalOpener: FakeManagedTerminal(), isolatedSocket: socket)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let failingRunner = LiveJournalFailureRunner()
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"), connectors: [TmuxConnector(runner: failingRunner)], managedController: controller)
        try runtime.start(); defer { runtime.stop() }
        let deadline = ContinuousClock.now + .seconds(60)
        var last = ManagedPaneSnapshot(screen: "", inputMetadata: "")
        clock.advance(10, wake: false)
        while runtime.managedStatus != .running(.idle) || runtime.sessions.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw ManagedSessionError.command("Live startup: \(runtime.managedStatus), \(last.inputMetadata), \(ManagedPaneClassifier.classify(last, agent: .claude))\n\(last.screen)")
            }
            if !controller.isBusy, let pane = controller.record?.pane {
                let capture = try await runner.run(executable: tmux, arguments: ["-S", socket, "capture-pane", "-p", "-t", pane.id], input: nil)
                let screen = String(decoding: capture.stdout, as: UTF8.self)
                last = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "") ?? last
                // The test human accepts only this disposable folder and fake localhost API key.
                // Never accept a tool, development-channel or other permission dialog.
                if screen.contains("Quick safety check:") && screen.contains("Yes, I trust this folder") {
                    _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Down", "Enter"], input: nil)
                } else if screen.contains("Do you want to use this API key?") {
                    _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Up", "Enter"], input: nil)
                }
                controller.refresh()
            }
            clock.advance(1, wake: false)
            try await Task.sleep(for: .milliseconds(250))
        }
        let pane = try #require(controller.record?.pane)
        let id = "d_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let lemon = "Suggestion test 2: reply through Zeus with the word LEMON."
        _ = await runtime.sendUserMessage(lemon, deliveryID: id)
        try await eventually { runtime.sends.isEmpty }
        let saved = try #require(runtime.ledger?.record(id: id))
        #expect(saved.delivery.meta["tmux_paste_destination"] != nil)
        #expect(saved.delivery.ackedAt == nil)
        try runtime.ledger?.update(id: id) { $0.attempts = 5; $0.failedAt = clock.now }
        let rendered = try #require(try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? ""))
        let input = try #require(TmuxInputSnapshot(metadata: Data(rendered.inputMetadata.utf8), screen: Data(rendered.screen.utf8)))
        #expect(input.containsOnlyClaudePaste(AgentInjectionText.format(saved.delivery)))
        runtime.stop()
        let resumedController = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables, environment: environment, clock: clock, terminalOpener: FakeManagedTerminal(), isolatedSocket: socket)
        let resumedRunner = LiveJournalRecordingRunner()
        let resumed = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(runner: resumedRunner)], managedController: resumedController)
        try resumed.start(); defer { resumed.stop() }
        let laterID = "d_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        _ = await resumed.sendUserMessage("Suggestion test 3: reply through Zeus with the word ORANGE.", deliveryID: laterID)
        let end = ContinuousClock.now + .seconds(40)
        while resumed.ledger?.records.allSatisfy({ $0.delivery.ackedAt != nil }) != true {
            guard ContinuousClock.now < end else {
                let frame = try await resumedController.hosting?.capture(pane, owner: resumedController.record?.owner ?? "")
                throw ManagedSessionError.command("Recovery did not unblock later input: \(String(describing: resumed.ledger?.records)); \(String(describing: frame))")
            }
            if !resumedController.isBusy { resumedController.refresh(); clock.advance(1, wake: true) }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(resumedController.record?.pane?.pid == pane.pid, "Runtime relaunch must retain the actual agent process")
        #expect(resumed.ledger?.record(id: id)?.delivery.attempts == 5)
        #expect(resumed.ledger?.record(id: id)?.delivery.failedAt == nil)
        #expect(resumed.ledger?.record(id: id)?.delivery.meta["tmux_paste_destination"] == nil)
        #expect(resumed.ledger?.record(id: laterID)?.delivery.attempts == 1)
        #expect(await resumedRunner.enters == 2, "One recovery Enter plus the later message's Enter")
        #expect(await resumedRunner.pastes == 1, "Only the later message may paste")
        #expect(cards.cards.filter { $0.body == "Live Claude received sequence message 2." }.count == 1)
        #expect(cards.cards.filter { $0.body == "Live Claude received sequence message 3." }.count == 1)
    }
}
