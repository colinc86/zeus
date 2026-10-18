import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

actor LiveClaudeCursorRunner: ProcessRunning {
    var moveAfterPaste: Bool
    let runner = FoundationProcessRunner()
    init(moveAfterPaste: Bool) { self.moveAfterPaste = moveAfterPaste }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        let result = try await runner.run(executable: executable, arguments: arguments, input: input)
        if moveAfterPaste, arguments.contains("paste-buffer"), result.status == 0 {
            moveAfterPaste = false
            guard let socketIndex = arguments.firstIndex(of: "-S"), arguments[socketIndex + 1].contains("/zlive_"),
                  let targetIndex = arguments.firstIndex(of: "-t") else { throw ConnectorError.inputChanged }
            _ = try await runner.run(executable: executable, arguments: ["-S", arguments[socketIndex + 1], "send-keys", "-t", arguments[targetIndex + 1], "Home"], input: nil)
        }
        return result
    }
}

/// Installed CLI + bundled bridge + real runtime/composer; model and HOME are disposable.
@MainActor
struct LiveClaudeDeliveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_LIVE_CLAUDE_BASE_URL"] != nil), .timeLimit(.minutes(2)), arguments: [false, true])
    func realClaudeReceivesComposeAndThirtySecondFallbackWithoutToolConsent(moveCursor: Bool) async throws {
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
        try Data("#!/bin/sh\ncat >/dev/null\ndate '+  Fixture status %H:%M:%S'\nprintf '  A second custom status line\\n'\n".utf8).write(to: statusline)
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
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"), connectors: [ChannelDeliveryConnector(), TmuxConnector(runner: LiveClaudeCursorRunner(moveAfterPaste: moveCursor))], managedController: controller)
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
        let inputBefore = try await controller.hosting?.capture(try #require(controller.record?.pane), owner: controller.record?.owner ?? "")
        let conversation = ConversationModel(cards: cards, messaging: runtime, clock: { clock.now })
        conversation.draft = "Live test from your PM: reply through Zeus with the word PINEAPPLE and today's weekday."
        let sent = await conversation.send()
        guard case .message(_, .delivered)? = sent else {
            let pane = try #require(controller.record?.pane)
            let captured = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
            throw ManagedSessionError.command("Compose result: \(String(describing: sent)); records: \(String(describing: runtime.ledger?.records)); before: \(String(describing: inputBefore)); pane: \(String(describing: captured))")
        }
        #expect(runtime.ledger?.records.first?.delivery.attempts == 1)
        let end = ContinuousClock.now + .seconds(20)
        while runtime.ledger?.records.first?.delivery.ackedAt == nil {
            guard ContinuousClock.now < end else {
                let pane = try #require(controller.record?.pane)
                let captured = try await controller.hosting?.capture(pane, owner: controller.record?.owner ?? "")
                throw ManagedSessionError.command("Live tool ack wasn't received; pane: \(String(describing: captured))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(cards.cards.contains { $0.body == "Live Claude received the compose message through its managed pane." })
        #expect(runtime.ledger?.records.count == 1 && conversation.draft.isEmpty)
        #expect(runtime.managedChannelReady.isEmpty)

        // Seed the existing readiness-ack path to simulate a channel that previously
        // worked but is no longer registered. This CLI deliberately has no channel;
        // the actual notification will go unanswered, then the same ID must reach
        // its pane and be acknowledged by the real bridge after the 30 s deadline.
        let key = try #require(controller.sessionKey)
        let idleDeadline = ContinuousClock.now + .seconds(10)
        repeat {
            guard ContinuousClock.now < idleDeadline else { throw ManagedSessionError.command("Live pane didn't become idle after its tool reply") }
            if !controller.isBusy { controller.refresh(); clock.advance(1, wake: false) }
            try await Task.sleep(for: .milliseconds(100))
        } while controller.isBusy || runtime.managedStatus != .running(.idle)
        let probe = try #require(runtime.managedChannelProbes[key])
        _ = await runtime.callTool("zeus_ack", arguments: ["delivery_ids": [.string(probe)]], sessionKey: key)
        #expect(runtime.managedChannelReady.contains(key))
        conversation.draft = "A second message after channel loss."
        guard case .message(_, .delivered)? = await conversation.send() else { Issue.record("Fixture channel push wasn't written"); return }
        let second = try #require(runtime.ledger?.records.last?.delivery.id)
        try await eventually { runtime.sends.isEmpty }
        #expect(runtime.ledger?.record(id: second)?.delivery.ackedAt == nil)
        clock.advance(29, wake: false); runtime.processDueDeliveries()
        #expect(runtime.ledger?.record(id: second)?.delivery.meta["managed_channel_fallback"] == nil)
        clock.advance(1, wake: false); runtime.processDueDeliveries()
        let fallbackDeadline = ContinuousClock.now + .seconds(20)
        while runtime.ledger?.record(id: second)?.delivery.ackedAt == nil {
            guard ContinuousClock.now < fallbackDeadline else { throw ManagedSessionError.command("Live fallback didn't get a real tool ack: \(String(describing: runtime.ledger?.record(id: second)))") }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(runtime.ledger?.record(id: second)?.delivery.meta["managed_channel_fallback"] == "true")
        #expect(runtime.ledger?.records.count == 2 && runtime.managedChannelReady.isEmpty)
        let permissionPane = try #require(controller.record?.pane)
        let permissionPrompt = "Zeus L9 permission fixture " + UUID().uuidString
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "load-buffer", "-b", "l9-fixture", "-"], input: Data(permissionPrompt.utf8))
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "paste-buffer", "-p", "-d", "-b", "l9-fixture", "-t", permissionPane.id], input: nil)
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", permissionPane.id, "Enter"], input: nil)
        let blockedDeadline = ContinuousClock.now + .seconds(20)
        while true {
            if case .blocked = runtime.managedStatus { break }
            guard ContinuousClock.now < blockedDeadline else { throw ManagedSessionError.command("Real permission prompt wasn't detected: \(runtime.managedStatus)") }
            if !controller.isBusy { controller.refresh(); clock.advance(3, wake: false) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initialPane = try #require(controller.record?.pane)
        let initialNativeID = try #require(controller.record?.conversation?.nativeID)
        for fresh in [false, true] {
            if fresh { controller.startNewManagedConversation() } else { controller.restartManagedSession() }
            let restartDeadline = ContinuousClock.now + .seconds(30)
            while controller.isBusy || controller.record?.pane?.pid == initialPane.pid || controller.managedStatus == .stopped {
                guard ContinuousClock.now < restartDeadline else { throw ManagedSessionError.command("Real restart: \(controller.managedStatus)") }
                try await Task.sleep(for: .milliseconds(100))
            }
            if case .failed = controller.managedStatus { throw ManagedSessionError.command("Real restart failed: \(controller.managedStatus)") }
            let next = try #require(controller.record?.pane)
            #expect(next.serverPID != initialPane.serverPID)
            #expect(fresh ? controller.record?.conversation?.nativeID != initialNativeID : controller.record?.conversation?.nativeID == initialNativeID)
            #expect(try await controller.hosting?.sessions().count == 1)
            let size = try await runner.run(executable: tmux, arguments: ["-S", socket, "display-message", "-p", "-t", next.id, "#{pane_width}x#{pane_height}"], input: nil)
            #expect(String(decoding: size.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "120x40")
        }
    }
}
