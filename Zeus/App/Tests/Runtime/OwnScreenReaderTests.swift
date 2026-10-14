import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

private actor OwnCaptureRunner: ProcessRunning {
    var calls: [[String]] = []
    var environments: [[String: String]] = []
    var dead = false
    var replace = false
    var inspected = 0
    var afterInspect: (@Sendable () async -> Void)?
    func set(dead: Bool = false, replace: Bool = false, afterInspect: (@Sendable () async -> Void)? = nil) {
        self.dead = dead; self.replace = replace; self.afterInspect = afterInspect
    }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult { throw ConnectorError.invalidURL }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        calls.append(arguments); environments.append(environment)
        #expect(input == nil)
        let value: String
        if arguments.contains("capture-pane") { value = "────────────────\n❯ \n────────────────\n" }
        else if arguments.last?.contains("cursor_x") == true { value = "2|1|120|0|1|1\n" }
        else {
            inspected += 1
            value = "/fixture/tmux.sock\t%0\t40\t$1\t\(replace && inspected > 1 ? 6 : 5)\t\(dead ? 1 : 0)\n"
            if inspected == 1 { await afterInspect?() }
        }
        return .init(status: 0, stdout: Data(value.utf8))
    }
}
@MainActor private final class OwnCaptureAuthorization { var allowed = true }
@MainActor struct OwnScreenReaderTests {
    nonisolated private static func identity(_ pid: Int) -> OwnSessionScreenReader.ProcessIdentity? {
        switch pid {
        case 17: .init(pid: 17, parent: 5, start: 100)
        case 5, 6: .init(pid: pid, parent: 40, start: 200)
        case 40: .init(pid: 40, parent: 1, start: 300)
        default: nil
        }
    }
    private func destination(start: UInt64 = 100) -> OwnSessionScreenDestination {
        .init(sessionKey: "claude:/fixture#17.\(start)", sessionID: UUID(), agent: .claude, pane: "%0", socket: "/fixture/tmux.sock", agentPID: 17, agentStart: start)
    }
    @Test func capturesOnlyReadCommandsWithExplicitNamespaceAndNoAmbientMetadata() async throws {
        let runner = OwnCaptureRunner()
        let reader = OwnSessionScreenReader(runner: runner, executable: { URL(fileURLWithPath: "/fixture/tmux") }, process: Self.identity,
            environment: ["TMUX": "/other/server,1,0", "TMUX_PANE": "%9"])
        let frame = try await reader.capture(destination(), stillAllowed: { true })
        #expect(frame.screen.hasPrefix("────────────────") && frame.inputMetadata == "2|1|120|0|1|1")
        #expect(await runner.calls.count == 4)
        #expect(await runner.calls.allSatisfy { $0.prefix(3) == ["-u", "-S", "/fixture/tmux.sock"] && ($0.contains("display-message") || $0.contains("capture-pane")) })
        #expect(await runner.environments.allSatisfy { $0["TMUX"] == nil && $0["TMUX_PANE"] == nil })
    }
    @Test(arguments: ["dead", "pid-reused", "replaced", "selection-changed"])
    func staleAndReplacedDestinationsCannotProduceEvidence(_ failure: String) async throws {
        let runner = OwnCaptureRunner(), authorization = OwnCaptureAuthorization()
        let callback: (@Sendable () async -> Void)?
        if failure == "selection-changed" { callback = { await MainActor.run { authorization.allowed = false } } }
        else { callback = nil }
        await runner.set(dead: failure == "dead", replace: failure == "replaced", afterInspect: callback)
        let reader = OwnSessionScreenReader(runner: runner, executable: { URL(fileURLWithPath: "/fixture/tmux") }, process: Self.identity)
        await #expect(throws: (any Error).self) {
            try await reader.capture(destination(start: failure == "pid-reused" ? 101 : 100), stillAllowed: { authorization.allowed })
        }
        if failure != "replaced" { #expect(await runner.calls.allSatisfy { !$0.contains("capture-pane") }) }
    }
}
