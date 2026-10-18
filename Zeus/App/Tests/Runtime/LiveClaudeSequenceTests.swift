import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// M8b sequence with real wall time and no suggestion setting/env override.
@MainActor
struct LiveClaudeSequenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_LIVE_CLAUDE_BASE_URL"] != nil), .timeLimit(.minutes(2)))
    func fiveConsecutiveMessagesWithDefaultSuggestionSettings() async throws {
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
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables, environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
                "PATH": "/usr/bin:/bin", "ANTHROPIC_BASE_URL": base.absoluteString, "ANTHROPIC_API_KEY": "l-local-fixture",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false"],
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
        let conversation = ConversationModel(cards: cards, messaging: runtime, clock: { clock.now })
        let messages = [
            "Suggestion test 1: reply through Zeus with the word CHERRY, and tell me I can say /assistant status next.",
            "Suggestion test 2: reply through Zeus with the word LEMON.",
            "Suggestion test 3: reply through Zeus with the word ORANGE.",
            "Suggestion test 4: reply through Zeus with the word MELON.",
            "Suggestion test 5: reply through Zeus with the word APPLE."
        ]
        for (index, text) in messages.enumerated() {
            if index == 1 {
                // Real wall time, not an advanced fake clock: reproduce M8b.
                for _ in 0..<20 {
                    try await Task.sleep(for: .seconds(1))
                    if !controller.isBusy { controller.refresh(); clock.advance(1, wake: false) }
                }
            }
            let end = ContinuousClock.now + .seconds(20)
            while controller.isBusy || runtime.managedStatus != .running(.idle) {
                guard ContinuousClock.now < end else { throw ManagedSessionError.command("Before sequence message \(index + 1): \(runtime.managedStatus)") }
                if !controller.isBusy { controller.refresh(); clock.advance(1, wake: false) }
                try await Task.sleep(for: .milliseconds(100))
            }
            conversation.draft = text
            guard case .message(_, .delivered)? = await conversation.send() else {
                let snapshot = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
                throw ManagedSessionError.command("Sequence message \(index + 1) did not submit: \(String(describing: runtime.ledger?.records)); \(String(describing: snapshot))")
            }
            let id = try #require(runtime.ledger?.records.last?.delivery.id)
            let body = "Live Claude received sequence message \(index + 1)."
            while runtime.ledger?.record(id: id)?.delivery.ackedAt == nil || !cards.cards.contains(where: { $0.body == body }) {
                guard ContinuousClock.now < end else { throw ManagedSessionError.command("Sequence message \(index + 1) did not get both tools") }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(runtime.ledger?.record(id: id)?.delivery.attempts == 1)
            #expect(cards.cards.filter { $0.body == body }.count == 1)
            #expect(runtime.ledger?.record(id: id)?.delivery.meta["tmux_paste_destination"] == nil)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(runtime.ledger?.records.count == 5 && runtime.ledger?.records.allSatisfy { !$0.isPending } == true)
    }
}
