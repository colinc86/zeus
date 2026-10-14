import Foundation
import Darwin
import Testing
import ZeusProtocol
@testable import Zeus

/// Uses production launch, native discovery, draft detection and resume with only
/// a disposable profile, private tmux namespace and localhost model.
@Suite(.serialized) @MainActor struct ManagedSettingsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_S3_LIVE"] == "1"), .timeLimit(.minutes(3)), arguments: [AgentKind.claude, .codex, .opencode])
    func realResumePicksUpInstructionsAndPermissionMode(agent: AgentKind) async throws {
        let executables = ManagedExecutables.detect()
        let tmux = try #require(executables.tmux), cli = try #require(executables.agents[agent])
        let root = URL(fileURLWithPath: "/private/tmp/zs3_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home"), folder = root.appendingPathComponent("project")
        let socket = root.appendingPathComponent("tmux.sock").path
        var launchedPanes: [ManagedPane] = []
        let model = Process(), logURL = root.appendingPathComponent("model.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            let cleanup = Process(); cleanup.executableURL = tmux; cleanup.arguments = ["-S", socket, "kill-server"]
            cleanup.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
            if model.isRunning { model.terminate(); model.waitUntilExit() }
            finishNativeExitWrites(launchedPanes, socket: socket)
            try? log.close(); try? FileManager.default.removeItem(at: root)
        }
        let python = try #require(["/opt/homebrew/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) })
        model.executableURL = URL(fileURLWithPath: python)
        model.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("S3LocalResumeModel.py").path,
                           "--root", root.path, "--agent", agent.rawValue]
        model.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        model.standardOutput = log; model.standardError = log
        try model.run()
        let startupDeadline = ContinuousClock.now + .seconds(70)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) {
            guard model.isRunning, ContinuousClock.now < startupDeadline else { throw ConnectorError.processTimeout }
            try await Task.sleep(for: .milliseconds(50))
        }
        let ready = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("ready.json")))
        let base = try #require(ready["baseURL"])
        let environment = ["HOME": home.path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
            "CODEX_HOME": home.appendingPathComponent(".codex").path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path, "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "ANTHROPIC_BASE_URL": base, "ANTHROPIC_API_KEY": "s3-local-fixture",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false",
            "OPENCODE_DISABLE_AUTOUPDATE": "true", "OPENCODE_DISABLE_EXTERNAL_PLUGINS": "true", "OPENCODE_DISABLE_MODELS_FETCH": "true", "OPENCODE_DISABLE_LSP_DOWNLOAD": "true"]
        let runner = FoundationProcessRunner()
        let routing = FakeRouting(), clock = TestRuntimeClock()
        let oldInstructions = "S3_ORIGINAL_INSTRUCTIONS. Reply briefly and do not run any tools."
        let newInstructions = "S3_UPDATED_INSTRUCTIONS. Continue this same conversation and reply briefly."
        routing.managedSession = .init(enabled: true, folder: folder.path, agent: agent, launchPrompt: oldInstructions, startWhenZeusOpens: true)
        let controller = ManagedSessionController(configuration: { routing.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: executables, environment: environment, clock: clock, terminalOpener: FakeManagedTerminal(), isolatedSocket: socket)
        let scoped = S3ScopedRunner(socket: socket, environment: environment)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let runtime = ZeusRuntime(cards: cards, status: FakeStatus(), characters: FakeCharacters(), routing: routing, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux, runner: scoped)], managedController: controller)
        try runtime.start(); defer { runtime.stop() }
        var last = ManagedPaneSnapshot(screen: "", inputMetadata: "")
        func settle() async throws {
            let deadline = ContinuousClock.now + .seconds(65)
            while true {
                if !controller.isBusy, let pane = controller.record?.pane {
                    last = try await #require(controller.hosting).capture(pane, owner: controller.record?.owner ?? "")
                    let plain = last.plainLines.joined(separator: "\n")
                    // The fixture human accepts only its scratch trust and synthetic key setup.
                    if agent == .claude, plain.contains("Quick safety check:"), plain.contains(folder.path), plain.contains("Yes, I trust this folder") {
                        _ = try await scoped.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Down", "Enter"], input: nil)
                    } else if agent == .claude, plain.contains("Do you want to use this API key?") {
                        _ = try await scoped.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Up", "Enter"], input: nil)
                    }
                    controller.refresh()
                    try await eventually { !controller.isBusy }
                }
                clock.advance(1, wake: false)
                if controller.managedStatus == .running(.idle), !controller.isBusy, !runtime.sessions.isEmpty,
                   controller.managedCanResumeSettings,
                   TmuxInputSnapshot(metadata: Data(last.inputMetadata.utf8), screen: Data(last.screen.utf8))?.isEmpty == true { return }
                guard ContinuousClock.now < deadline else {
                    throw ManagedSessionError.command("S3 \(agent): \(controller.managedStatus)\n\(last.screen.replacingOccurrences(of: root.path, with: "/FIXTURE"))")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        try await settle()
        let original = try #require(controller.record?.conversation), previousPane = try #require(controller.record?.pane)
        launchedPanes.append(previousPane)
        let originalRequests = try requests(root)
        #expect(originalRequests.contains { instructionStrings($0).contains { $0.contains("S3_ORIGINAL_INSTRUCTIONS") } })
        var config = try #require(routing.managedSession)
        config.permissionModeID = ManagedAgentLaunch.policies(for: agent)[1].mode.id
        config.launchPrompt = newInstructions
        routing.managedSession = config
        runtime.applyManagedSettings(config)
        let resumeDeadline = ContinuousClock.now + .seconds(30)
        while controller.isBusy || controller.record?.pane?.pid == previousPane.pid {
            guard ContinuousClock.now < resumeDeadline else { throw ManagedSessionError.command("S3 resume: \(controller.managedStatus), \(String(describing: controller.managedSettingsApplication)), \(controller.managedSettingsApplicationError ?? "no error")") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settle()
        if let pane = controller.record?.pane { launchedPanes.append(pane) }
        #expect(controller.record?.conversation?.nativeID == original.nativeID)
        #expect(controller.record?.conversation?.nonce == original.nonce)
        let supported = controller.supportsInstructionChangesOnResume(for: agent)
        #expect(controller.managedAppliedConfiguration?.launchPrompt == (supported ? newInstructions : oldInstructions))
        let result = await runtime.sendUserMessage("S3_RESUME_PROBE", deliveryID: "d_3333abcd")
        #expect(result == .delivered)
        let deadline = ContinuousClock.now + .seconds(25)
        var updatedRole = false
        while ContinuousClock.now < deadline {
            let resumed = try requests(root).dropFirst(originalRequests.count)
            updatedRole = resumed.contains { instructionStrings($0).contains { $0.contains("S3_UPDATED_INSTRUCTIONS") } }
            let received = resumed.contains { allStrings($0).contains { $0.contains("S3_RESUME_PROBE") } }
            if updatedRole || (!supported && received) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let resumedRequests = try requests(root).dropFirst(originalRequests.count)
        let anyRole = resumedRequests.contains { allStrings($0).contains { $0.contains("S3_UPDATED_INSTRUCTIONS") } }
        #expect(updatedRole == supported, "New instructions in any role: \(anyRole); advertised support: \(supported)")
        if !supported { #expect(resumedRequests.contains { instructionStrings($0).contains { $0.contains("S3_ORIGINAL_INSTRUCTIONS") } }) }
        try await settle()
        if agent == .codex, let pane = controller.record?.pane {
            _ = try await scoped.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "-l", "/status"], input: nil)
            _ = try await scoped.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Enter"], input: nil)
            try await Task.sleep(for: .milliseconds(400))
            _ = try await scoped.run(executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane.id, "Enter"], input: nil)
            try await Task.sleep(for: .milliseconds(400))
            last = try await #require(controller.hosting).capture(pane, owner: controller.record?.owner ?? "")
        }
        let plain = last.plainLines.joined(separator: "\n").lowercased()
        if agent == .claude { #expect(plain.contains("plan mode")) }
        if agent == .codex { #expect(plain.contains("read only") || plain.contains("read-only")) }
        if agent == .opencode {
            let policy = await runtime.sendUserMessage("S3_POLICY_PROBE", deliveryID: "d_3333abce")
            #expect(policy == .delivered)
            let deadline = ContinuousClock.now + .seconds(20)
            var denied = false
            while ContinuousClock.now < deadline {
                let text = try requests(root).flatMap(toolOutputs).joined(separator: "\n").lowercased()
                let all = try requests(root)
                let originalTools = originalRequests.contains { toolNames($0).contains("bash") }
                let probe = all.filter { allStrings($0).contains { $0.contains("S3_POLICY_PROBE") } }
                let filtered = originalTools && !probe.isEmpty && probe.allSatisfy { !toolNames($0).contains("bash") }
                denied = filtered || (FileManager.default.fileExists(atPath: root.appendingPathComponent("policy-tool.json").path)
                    && (text.contains("rejected permission") || text.contains("permission is denied") || text.contains("deny")))
                if denied { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(denied, "The resumed OpenCode must deny the fixture's Bash tool under its new policy")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("s3-policy.txt").path))
            try await settle()
            if let pane = controller.record?.pane { last = try await #require(controller.hosting).capture(pane, owner: controller.record?.owner ?? "") }
        }
        if ProcessInfo.processInfo.environment["ZEUS_S3_RECORD_FIXTURES"] == "1" {
            var worktree = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { worktree.deleteLastPathComponent() }
            let evidence = worktree.appendingPathComponent("TestFixtures/live/s3/" + agent.rawValue)
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try Data(last.screen.replacingOccurrences(of: root.path, with: "/FIXTURE").utf8).write(to: evidence.appendingPathExtension("ansi"))
            let version = try await runner.run(executable: cli, arguments: ["--version"], input: nil, environment: environment)
            let facts: [String: JSONValue] = ["agent": .string(agent.rawValue), "version": .string(String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)),
                "same_native_id": .bool(controller.record?.conversation?.nativeID == original.nativeID), "new_instructions_in_model_role": .bool(updatedRole),
                "permission_mode": .string(config.permissionModeID ?? "default"), "instruction_resume_supported": .bool(supported)]
            try JSONEncoder().encode(facts).write(to: evidence.appendingPathExtension("json"))
            let debug = worktree.appendingPathComponent("build/s3/\(agent.rawValue)-requests.ndjson")
            try Data(String(contentsOf: root.appendingPathComponent("requests.ndjson"), encoding: .utf8).replacingOccurrences(of: root.path, with: "/FIXTURE").utf8).write(to: debug)
        }
    }
    private func requests(_ root: URL) throws -> [JSONValue] {
        let text = try String(contentsOf: root.appendingPathComponent("requests.ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
    private func allStrings(_ value: JSONValue) -> [String] {
        switch value { case .string(let s): [s]; case .array(let a): a.flatMap(allStrings); case .object(let o): o.values.flatMap(allStrings); default: [] }
    }
    private func toolNames(_ request: JSONValue) -> [String] {
        guard case .object(let fields) = request, case .array(let tools) = fields["tools"] else { return [] }
        return tools.compactMap { tool in
            guard case .object(let item) = tool else { return nil }
            if case .string(let name) = item["name"] { return name }
            if case .object(let function) = item["function"], case .string(let name) = function["name"] { return name }
            return nil
        }
    }
    /// Synchronous defer cleanup: the private CLI may still be flushing its store
    /// after tmux returns from kill-server. No test UI or user process is involved.
    private func finishNativeExitWrites(_ panes: [ManagedPane], socket: String) {
        for pane in panes where pane.socket == socket && socket.contains("/zs3_") {
            guard let pid = Int32(exactly: pane.pid) else { continue }
            var info = proc_bsdinfo()
            let size = MemoryLayout.size(ofValue: info)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
                  info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == pane.startTime else { continue }
            // Only a fixture-launched lifetime, after killing its private server.
            _ = kill(pid, SIGTERM)
            let end = Date().addingTimeInterval(2)
            while kill(pid, 0) == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.025) }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    private func instructionStrings(_ request: JSONValue) -> [String] {
        guard case .object(let fields) = request else { return [] }
        func strings(_ value: JSONValue) -> [String] {
            switch value { case .string(let s): [s]; case .array(let a): a.flatMap(strings); case .object(let o): o.values.flatMap(strings); default: [] }
        }
        let roles = ["input", "messages"].flatMap { key -> [String] in
            guard case .array(let items) = fields[key] else { return [] }
            return items.flatMap { item -> [String] in
                guard case .object(let entry) = item, entry["role"] == "system" || entry["role"] == "developer" else { return [] }
                return strings(item)
            }
        }
        return roles + ["system", "instructions"].flatMap { fields[$0].map(strings) ?? [] }
    }
    private func toolOutputs(_ request: JSONValue) -> [String] {
        guard case .object(let fields) = request else { return [] }
        func strings(_ value: JSONValue) -> [String] {
            switch value { case .string(let s): [s]; case .array(let a): a.flatMap(strings); case .object(let o): o.values.flatMap(strings); default: [] }
        }
        return ["input", "messages"].flatMap { key -> [String] in
            guard case .array(let items) = fields[key] else { return [] }
            return items.flatMap { item -> [String] in
                guard case .object(let entry) = item, entry["role"] == "tool" || entry["type"] == "function_call_output" else { return [] }
                return strings(item)
            }
        }
    }
}

private struct S3ScopedRunner: ProcessRunning {
    let socket: String
    let environment: [String: String]
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard socket.contains("/zs3_"), let index = arguments.firstIndex(of: "-S"), arguments.indices.contains(index + 1), arguments[index + 1] == socket else {
            throw ConnectorError.missingTmuxSocket
        }
        return try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input, environment: environment)
    }
}
