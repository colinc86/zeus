import Foundation
import Testing
@testable import Zeus

actor AddPrivateSessionDuringRemoval: ProcessRunning {
    let runner = FoundationProcessRunner()
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        throw ConnectorError.processIO // Tests must pass an explicit disposable environment.
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        if arguments.contains("kill-pane"), let socket = arguments.firstIndex(of: "-S") {
            _ = try await runner.run(executable: executable, arguments: ["-S", arguments[socket + 1], "new-session", "-d", "-s", "human-fixture", "/bin/sleep", "86400"], input: nil, environment: environment)
        }
        return try await runner.run(executable: executable, arguments: arguments, input: input, environment: environment)
    }
}

@MainActor
struct ManagedLastPaneTests {
    @Test(arguments: [0, 1, 2])
    func recreateAfterLastOwnedPaneClosesTheServerOrLeavesItEmpty(mode: Int) async throws {
        let tmux = try #require(TmuxExecutable.resolve())
        let root = URL(fileURLWithPath: "/tmp/zlast_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let runner = FoundationProcessRunner()
        defer {
            let cleanup = Process(); cleanup.executableURL = tmux; cleanup.arguments = ["-S", socket, "kill-server"]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit(); try? FileManager.default.removeItem(at: root)
        }
        let exitEmpty = mode != 1
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        let host = ManagedTmux(executable: tmux, environment: environment, testSocket: socket)
        let first = try await host.create(name: "zeus", owner: "private-fixture", folder: root.path)
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "set-option", "-s", "exit-empty", exitEmpty ? "on" : "off"], input: nil)
                let removing = mode == 2 ? ManagedTmux(executable: tmux, runner: AddPrivateSessionDuringRemoval(), environment: environment, testSocket: socket) : host
        try await removing.removePane(first, owner: "private-fixture")
        #expect(try await host.sessions().count == (mode == 2 ? 1 : 0))
        let next = try await host.create(name: "zeus", owner: "private-fixture", folder: root.path)
        #expect(mode == 0 ? next.serverPID != first.serverPID : next.serverPID == first.serverPID)
        if mode == 2 {
            let human = try await runner.run(executable: tmux, arguments: ["-S", socket, "has-session", "-t", "=human-fixture"], input: nil)
            #expect(human.status == 0, "Another client's new session must be left alone")
        }
        let size = try await runner.run(executable: tmux, arguments: ["-S", socket, "display-message", "-p", "-t", next.id, "#{pane_width}x#{pane_height}"], input: nil)
        #expect(String(decoding: size.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "120x40")
    }
}
