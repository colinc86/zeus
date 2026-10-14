import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Real generated suggestions, never a hand-painted terminal frame; disposable profiles only.
@MainActor
struct LiveClaudeSuggestionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_LIVE_CLAUDE_BASE_URL"] != nil), .timeLimit(.minutes(2)), arguments: ["dark", "light"])
    func realClaudeSuggestionDoesNotEnterTheSubmittedMessage(theme: String) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["ZEUS_LIVE_CLAUDE_BASE_URL"].flatMap(URL.init(string:)))
        try #require(base.host == "127.0.0.1")
        let executables = ManagedExecutables.detect()
        let tmux = try #require(executables.tmux)
        try #require(executables.agents[.claude] != nil)
        let root = URL(fileURLWithPath: "/tmp/zlive_" + UUID().uuidString.prefix(8))
        let home = root.appendingPathComponent("home"), folder = root.appendingPathComponent("project")
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
        let profile = try JSONSerialization.data(withJSONObject: ["hasCompletedOnboarding": true, "theme": theme, "hasAcknowledgedCostThreshold": true])
        try profile.write(to: home.appendingPathComponent(".claude.json"))
        try profile.write(to: home.appendingPathComponent(".claude/.claude.json"))
        let statusline = home.appendingPathComponent("statusline.sh")
        try Data("#!/bin/sh\ncat >/dev/null\ndate '+  Fixture status %H:%M:%S'\nprintf '  A second custom status line\\n'\n".utf8).write(to: statusline)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: statusline.path)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": statusline.path, "refreshInterval": 1], "promptSuggestionEnabled": true])
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let routing = FakeRouting(), clock = TestRuntimeClock()
        routing.managedSession = .init(enabled: true, folder: folder.path, agent: .claude, launchPrompt: "Use Zeus for replies.", startWhenZeusOpens: true)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables, environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
                "PATH": "/usr/bin:/bin", "ANTHROPIC_BASE_URL": base.absoluteString, "ANTHROPIC_API_KEY": "l-local-fixture",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false", "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "1"],
            clock: clock, terminalOpener: FakeManagedTerminal(), isolatedSocket: socket)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"), connectors: [ChannelDeliveryConnector(), TmuxConnector()], managedController: controller)
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
        // Claude skips suggestions until there are two assistant responses.
        // This test human supplies a harmless second turn in the private pane.
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "load-buffer", "-b", "suggestion-fixture", "-"],
            input: Data("Prepare the assistant and suggest its next step.".utf8))
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "paste-buffer", "-p", "-d", "-b", "suggestion-fixture", "-t", pane.id], input: nil)
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Enter"], input: nil)
        func suggestion(_ phase: String) async throws -> ManagedPaneSnapshot {
            let end = ContinuousClock.now + .seconds(30)
            var ghost = ManagedPaneSnapshot(screen: "", inputMetadata: "")
            while true {
                ghost = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "") ?? ghost
                if ghost.plainLines.contains(where: { $0.hasPrefix("❯") && $0.contains("/assistant arm") }) { break }
                guard ContinuousClock.now < end else { throw ManagedSessionError.command("No real suggestion before \(phase): \(ghost)") }
                try await Task.sleep(for: .milliseconds(200))
            }
            var evidence = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { evidence.deleteLastPathComponent() }
            evidence.appendPathComponent("build/l5-claude-ghost-" + theme + "-" + phase + ".json")
            try JSONSerialization.data(withJSONObject: ["screen": ghost.screen, "inputMetadata": ghost.inputMetadata]).write(to: evidence)
            let input = try #require(TmuxInputSnapshot(metadata: Data(ghost.inputMetadata.utf8), screen: Data(ghost.screen.utf8)))
            #expect(input.isEmpty, "A real CLI suggestion must not be an unsent human draft")
            while controller.isBusy { try await Task.sleep(for: .milliseconds(20)) }
            controller.refresh()
            while controller.isBusy { try await Task.sleep(for: .milliseconds(20)) }
            return ghost
        }
        func received(_ kind: Delivery.Kind, body: String) async throws {
            let end = ContinuousClock.now + .seconds(20)
            while !(runtime.ledger?.records.contains(where: { $0.delivery.kind == kind && $0.delivery.ackedAt != nil }) == true)
                    || !cards.cards.contains(where: { $0.body == body }) {
                guard ContinuousClock.now < end else {
                    let snapshot = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
                    throw ManagedSessionError.command("Live \(kind) did not arrive: \(String(describing: runtime.ledger?.records)); \(String(describing: snapshot))")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(cards.cards.filter { $0.body == body }.count == 1)
        }
        _ = try await suggestion("option")
        let ask = try #require(cards.cards.first { $0.options.contains { $0.id == "remove" } })
        #expect(cards.respond(id: ask.id, response: .init(optionID: "remove", optionLabel: "Remove Pixel Agents hooks", device: .mac)))
        try await received(.reply, body: "Live Claude received the option answer through its managed pane.")
        #expect(runtime.ledger?.records.first?.delivery.attempts == 1)
        #expect(runtime.ledger?.records.first?.delivery.meta["option_id"] == "remove")
        _ = try await suggestion("compose")
        let conversation = ConversationModel(cards: cards, messaging: runtime, clock: { clock.now })
        conversation.draft = "Hello?"
        let sent = await conversation.send()
        guard case .message(_, .delivered)? = sent else {
            throw ManagedSessionError.command("Compose over suggestion: \(String(describing: sent)); ledger: \(String(describing: runtime.ledger?.records))")
        }
        try await received(.userMessage, body: "Live Claude received the compose message through its managed pane.")
        #expect(runtime.ledger?.records.last?.delivery.attempts == 1)
        #expect(runtime.ledger?.records.count == 2 && conversation.draft.isEmpty)
        #expect(runtime.managedChannelReady.isEmpty)
        // Accepting a suggestion turns it into deliberate input. Moving Home
        // afterward must not make that actual draft look empty.
        _ = try await suggestion("accepted-control")
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Right", "Home"], input: nil)
        try await Task.sleep(for: .milliseconds(100))
        let accepted = try #require(try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? ""))
        let acceptedInput = try #require(TmuxInputSnapshot(metadata: Data(accepted.inputMetadata.utf8), screen: Data(accepted.screen.utf8)))
        #expect(!acceptedInput.isEmpty)

    }
}
