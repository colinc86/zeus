import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

actor N1ScopedRunner: ProcessRunning {
    let socket: String
    let home: URL
    let evidence: URL?
    let scrubRoot: String
    private var metadata = Data(), screen = Data()
    private var label = "before"
    private var entries = 0
    init(socket: String, home: URL, evidence: URL?, scrubRoot: String) {
        self.socket = socket; self.home = home; self.evidence = evidence; self.scrubRoot = scrubRoot
    }
    func setLabel(_ value: String) { label = value }
    func enterCount() -> Int { entries }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard let i = arguments.firstIndex(of: "-S"), arguments.indices.contains(i + 1), arguments[i + 1] == socket,
              socket.contains("/zn1_") else { throw ConnectorError.missingTmuxSocket }
        if arguments.contains("send-keys"), arguments.last == "Enter" {
            entries += 1
            if let evidence {
                try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
                try Data(String(decoding: screen, as: UTF8.self).replacingOccurrences(of: scrubRoot, with: "/FIXTURE").utf8)
                    .write(to: evidence.appendingPathComponent(label + ".ansi"))
                try metadata.write(to: evidence.appendingPathComponent(label + ".meta"))
            }
        }
        let result = try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input,
            environment: ["HOME": home.path, "TMUX_TMPDIR": home.appendingPathComponent("tmux").path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"])
        if arguments.contains("display-message") { metadata = result.stdout }
        if arguments.contains("capture-pane") { screen = result.stdout }
        return result
    }
    func snapshot(tmux: URL) async throws -> TmuxInputSnapshot? {
        let meta = try await run(executable: tmux, arguments: ["-u", "-S", socket, "display-message", "-p", "-t", "%0", "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}|#{bracket_paste_flag}"], input: nil)
        let screen = try await run(executable: tmux, arguments: ["-u", "-S", socket, "capture-pane", "-p", "-e", "-t", "%0"], input: nil)
        return TmuxInputSnapshot(metadata: meta.stdout, screen: screen.stdout)
    }
    func recordEmpty() throws {
        if let evidence {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try Data(String(decoding: screen, as: UTF8.self).replacingOccurrences(of: scrubRoot, with: "/FIXTURE").utf8)
                .write(to: evidence.appendingPathComponent(label + ".ansi"))
            try metadata.write(to: evidence.appendingPathComponent(label + ".meta"))
        }
    }
}

@Suite(.serialized) @MainActor struct N1LiveDeliveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_N1_LIVE"] == "1"), .timeLimit(.minutes(3)), arguments: [AgentKind.claude, .codex, .opencode])
    func realCLIReceivesOneCompleteMultilineMessage(agent: AgentKind) async throws {
        try await check(agent: agent)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_N1_LIVE"] == "1"), .timeLimit(.minutes(3)))
    func realOpenCodeWithPasteSummariesReceivesTheExactHiddenText() async throws {
        try await check(agent: .opencode, summaries: true)
    }

    private func check(agent: AgentKind, summaries: Bool = false) async throws {
        let executables = ManagedExecutables.detect()
        let tmux = try #require(executables.tmux), cli = try #require(executables.agents[agent])
        let root = URL(fileURLWithPath: "/private/tmp/zn1_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process(), log = root.appendingPathComponent("fixture.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? handle.close()
            try? FileManager.default.removeItem(at: root)
        }
        let python = try #require(["/opt/homebrew/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) })
        process.executableURL = URL(fileURLWithPath: python)
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("N1LocalModel.py")
        process.arguments = [helper.path, "--root", root.path, "--agent", agent.rawValue, "--tmux", tmux.path, "--cli", cli.path]
        if summaries { process.arguments?.append("--paste-summary") }
        process.environment = ["HOME": root.path, "PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now + .seconds(70)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) {
            guard process.isRunning, ContinuousClock.now < deadline else { throw ConnectorError.processTimeout }
            try await Task.sleep(for: .milliseconds(100))
        }
        var worktree = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { worktree.deleteLastPathComponent() }
        let evidence = ProcessInfo.processInfo.environment["ZEUS_N1_RECORD_FIXTURES"] == "1"
            ? worktree.appendingPathComponent("TestFixtures/live/n1/" + agent.rawValue + (summaries ? "-summary" : "")) : nil
        let runner = N1ScopedRunner(socket: root.appendingPathComponent("tmux.sock").path, home: root.appendingPathComponent("home"), evidence: evidence, scrubRoot: root.path)
        func ready(_ snapshot: TmuxInputSnapshot) -> Bool {
            snapshot.isEmpty && snapshot.acceptsMultilinePaste
                && !snapshot.lines.contains { $0.contains("esc interrupt") || $0.contains("loading") }
        }
        while true {
            if let snapshot = try await runner.snapshot(tmux: tmux), ready(snapshot) { break }
            guard ContinuousClock.now < deadline else {
                try await runner.recordEmpty()
                throw ConnectorError.processTimeout
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        try await runner.recordEmpty()
        let session = ConnectedSession(id: UUID(), sessionKey: "\(agent.rawValue):/fixture#1.1", agent: agent, cwd: "/fixture", clientName: nil,
            supportsChannel: false, tmuxPane: "%0", connectedAt: Date(), tmuxSocketPath: root.appendingPathComponent("tmux.sock").path)
        let routing = FakeRouting(); routing.deliveryMethod = .tmux
        let connector = TmuxConnector(executable: tmux, runner: runner)
        for index in N1Messages.names.indices {
            let until = ContinuousClock.now + .seconds(20)
            while !(try await runner.snapshot(tmux: tmux).map(ready) == true) {
                guard ContinuousClock.now < until else { throw ConnectorError.processTimeout }
                try await Task.sleep(for: .milliseconds(100))
            }
            let name = N1Messages.names[index]
            await runner.setLabel(name + "-before")
            try await runner.recordEmpty()
            await runner.setLabel(name)
            let delivery = N1Messages.delivery(index, agent: agent, sessionKey: session.sessionKey)
            do { try await connector.deliver(delivery, to: session, bridge: nil, routing: routing) }
            catch {
                let snapshot = try await runner.snapshot(tmux: tmux)
                try await runner.recordEmpty()
                throw ManagedSessionError.command("N1 \(agent) \(name): \(error); \(snapshot.map { $0.lines.joined(separator: "\n").replacingOccurrences(of: root.path, with: "/FIXTURE") } ?? "unknown snapshot")")
            }
            let expected = AgentInjectionText.format(delivery)
            // OpenCode expands its virtual paste token including the appended
            // editor separator space. All envelope/body bytes before it must match.
            let modelInput = expected + (summaries ? " " : "")
            func strings(_ value: JSONValue) -> [String] {
                switch value { case .string(let s): [s]; case .array(let a): a.flatMap(strings); case .object(let o): o.values.flatMap(strings); default: [] }
            }
            var received = false
            while ContinuousClock.now < until {
                if let data = try? Data(contentsOf: root.appendingPathComponent("requests.ndjson")),
                   let text = String(data: data, encoding: .utf8) {
                    let values = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                    received = values.contains { strings($0).contains(modelInput) }
                }
                if received { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(received, "The real CLI must send all original line breaks in one model input")
            #expect(await runner.enterCount() == index + 1)
        }
    }
}
