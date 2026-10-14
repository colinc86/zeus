import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Prefixes an isolated tmux server socket, keeping test panes separate from the user's sessions.
private struct IsolatedTmuxRunner: ProcessRunning {
    let socketName: String
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await FoundationProcessRunner().run(executable: executable, arguments: ["-L", socketName, "-f", "/dev/null"] + arguments, input: input)
    }
}

@MainActor
struct TmuxIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_TEST_TMUX"] == "1"))
    func realTmuxPastesIntoScratchCatPane() async throws {
        let executable = try #require(TmuxExecutable.resolve())
        let runner = IsolatedTmuxRunner(socketName: "zeus-p4-" + UUID().uuidString.prefix(8))
        do {
            let created = try await runner.run(executable: executable, arguments: ["new-session", "-d", "-s", "scratch", "-x", "300", "-y", "20", "/bin/sh", "-c", "printf '\\033c'; exec /bin/cat"], input: nil)
            try #require(created.status == 0)
            let listed = try await runner.run(executable: executable, arguments: ["list-panes", "-t", "scratch", "-F", "#{pane_id}"], input: nil)
            let pane = String(decoding: listed.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(!pane.isEmpty)
            let routing = FakeRouting(); routing.deliveryMethod = .tmux; routing.tmuxTarget = pane
            let socketResult = try await runner.run(executable: executable, arguments: ["display-message", "-p", "-t", pane, "#{socket_path}"], input: nil)
            let socket = String(decoding: socketResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            routing.tmuxTargetSocketPath = socket
            let session = connectorSession(socket: socket)
            let delivery = Delivery(id: "d_12345678", kind: .userMessage, sessionKey: session.sessionKey, content: "Hello real tmux.")
            // Await a fresh input surface; a newly spawned pane may still be
            // initializing terminal modes. This sink has no interactive shell.
            let readyDeadline = ContinuousClock.now + .seconds(2)
            while true {
                let metadata = try await runner.run(executable: executable, arguments: ["display-message", "-p", "-t", pane, "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}"], input: nil)
                let screen = try await runner.run(executable: executable, arguments: ["capture-pane", "-p", "-e", "-t", pane], input: nil)
                if TmuxInputSnapshot(metadata: metadata.stdout, screen: screen.stdout)?.isEmpty == true { break }
                guard ContinuousClock.now < readyDeadline else {
                    throw RuntimeTestError.deadline
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await TmuxConnector(executable: executable, runner: runner).deliver(delivery, to: session, bridge: nil, routing: routing)
            var captured = ""
            let end = ContinuousClock.now + .seconds(2)
            repeat {
                let result = try await runner.run(executable: executable, arguments: ["capture-pane", "-p", "-J", "-t", pane], input: nil)
                captured = String(decoding: result.stdout, as: UTF8.self)
                if captured.contains(AgentInjectionText.format(delivery)) { break }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < end
            #expect(captured.contains(AgentInjectionText.format(delivery)))
            let buffers = try await runner.run(executable: executable, arguments: ["list-buffers", "-F", "#{buffer_name}"], input: nil)
            #expect(!String(decoding: buffers.stdout, as: UTF8.self).contains("zeus-d_12345678"))
            _ = try await runner.run(executable: executable, arguments: ["kill-server"], input: nil)
        } catch {
            _ = try? await runner.run(executable: executable, arguments: ["kill-server"], input: nil)
            throw error
        }
    }
}
