import Foundation
import Testing
@testable import Zeus

private actor NamespaceDiscoveryRunner: ProcessRunning {
    var arguments: [[String]] = []
    var environments: [[String: String]] = []
    var executables: [URL] = []
    private var slowReply: CheckedContinuation<Void, Never>?
    private var slowStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    func waitForSlowStart() async {
        if slowStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func releaseSlowReply() { slowReply?.resume(); slowReply = nil }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input, environment: [:])
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        self.arguments.append(arguments); environments.append(environment); executables.append(executable)
        if arguments.contains(where: { $0.hasSuffix("/slow.sock") }) {
            await withCheckedContinuation { continuation in
                slowReply = continuation; slowStarted = true
                startWaiter?.resume(); startWaiter = nil
            }
        }
        return .init(status: 0, stdout: Data("%0 fixture:0.0 cat /fixture\n".utf8))
    }
}

@MainActor struct TmuxNamespaceDiscoveryTests {
    @Test func refreshReresolvesUserLocalInstallsAndRemovalsWithTheSharedSearchPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-discovery-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["HOME": root.path, "PATH": root.appendingPathComponent("custom/bin").path,
                   "TMUX": "/fixture/ambient.sock,1,0", "TMUX_PANE": "%99"]
        let runner = NamespaceDiscoveryRunner()
        let discovery = TmuxPaneDiscovery(runner: runner, environment: env)
        // Even when tmux is already installed system-wide this fake runner never opens a server.
        await discovery.refresh(socketPath: root.appendingPathComponent("isolated.sock").path)
        let first = root.appendingPathComponent(".opencode/bin/tmux")
        func install(_ binary: URL) throws {
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }
        try install(first)
        await discovery.refresh(socketPath: root.appendingPathComponent("isolated.sock").path)
        #expect(await runner.executables.last == first)
        #expect(discovery.error == nil && discovery.panes.first?.id == "%0")
        let second = root.appendingPathComponent(".local/bin/tmux")
        try install(second)
        await discovery.refresh(socketPath: root.appendingPathComponent("isolated.sock").path)
        #expect(await runner.executables.last == second)
        try FileManager.default.removeItem(at: second)
        await discovery.refresh(socketPath: root.appendingPathComponent("isolated.sock").path)
        #expect(await runner.executables.last == first)
        #expect(TmuxPaneDiscovery.resolveExecutable(environment: env) == TmuxExecutable.resolve(environment: env))
        let environments = await runner.environments
        #expect(environments.allSatisfy { $0["TMUX"] == nil && $0["TMUX_PANE"] == nil })
    }

    @Test func absentNamespaceNeverQueriesAnAmbientServerAndExplicitNamespaceClearsInheritedMetadata() async {
        let runner = NamespaceDiscoveryRunner()
        let discovery = TmuxPaneDiscovery(executable: URL(fileURLWithPath: "/bin/cat"), runner: runner,
                                          environment: ["TMUX": "/wrong/server,1,0", "TMUX_PANE": "%99", "PATH": "/usr/bin:/bin"])
        await discovery.refresh(socketPath: nil, assistantName: "Codex")
        #expect(await runner.arguments.isEmpty && discovery.panes.isEmpty && discovery.error == nil)
        #expect(discovery.guidance == "Choose the Codex session under Assistant session to list its panes.")
        await discovery.refresh(socketPath: "/tmp/desired.sock")
        #expect(discovery.guidance == nil)
        let arguments = await runner.arguments
        let environments = await runner.environments
        #expect(arguments.first?.prefix(3) == ["-u", "-S", AppSettings.normalizedTmuxSocket("/tmp/desired.sock") ?? ""])
        #expect(environments.first?["TMUX"] == nil && environments.first?["TMUX_PANE"] == nil)
        #expect(discovery.panes.first?.socketPath == AppSettings.normalizedTmuxSocket("/tmp/desired.sock"))
    }
    @Test func lateOldNamespaceResponseCannotReplaceANewerSelection() async throws {
        let runner = NamespaceDiscoveryRunner()
        let discovery = TmuxPaneDiscovery(executable: URL(fileURLWithPath: "/bin/cat"), runner: runner)
        let old = Task { await discovery.refresh(socketPath: "/tmp/slow.sock") }
        await runner.waitForSlowStart()
        await discovery.refresh(socketPath: "/tmp/new.sock")
        await runner.releaseSlowReply()
        await old.value
        #expect(discovery.panes.first?.socketPath == AppSettings.normalizedTmuxSocket("/tmp/new.sock"))
    }
    @Test func duplicatePaneNumbersOnTwoRealPrivateServersStayPairedWithTheirOwnNamespaces() async throws {
        let tmux = try #require(TmuxExecutable.resolve())
        let root = URL(fileURLWithPath: "/tmp/znsui_" + UUID().uuidString.prefix(8))
        let a = root.appendingPathComponent("a.sock").path, b = root.appendingPathComponent("b.sock").path
        let runner = FoundationProcessRunner()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for socket in [a, b] {
                let process = Process(); process.executableURL = tmux; process.arguments = ["-S", socket, "kill-server"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try? process.run(); process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: root)
        }
        for name in ["A", "B"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let socket = name == "A" ? a : b
            let result = try await runner.run(executable: tmux, arguments: ["-u", "-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "fixture", "-c", folder.path, "/bin/cat"], input: nil,
                                               environment: ["PATH": "/usr/bin:/bin"])
            try #require(result.status == 0)
        }
        let discovery = TmuxPaneDiscovery(executable: tmux, environment: ["TMUX": a + ",1,0", "TMUX_PANE": "%0", "PATH": "/usr/bin:/bin"])
        await discovery.refresh(socketPath: b)
        let paneB = try #require(discovery.panes.first)
        #expect(paneB.id == "%0" && paneB.path.hasSuffix("/B") && paneB.socketPath == AppSettings.normalizedTmuxSocket(b))
        await discovery.refresh(socketPath: a)
        let paneA = try #require(discovery.panes.first)
        #expect(paneA.id == paneB.id && paneA.path.hasSuffix("/A") && paneA.socketPath != paneB.socketPath)
    }
}
