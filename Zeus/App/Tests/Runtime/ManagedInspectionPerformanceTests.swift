import Darwin
import Foundation
import Testing
@testable import Zeus

private actor InspectionBatchRunner: ProcessRunning {
    let output: String
    private(set) var calls: [[String]] = []
    init(_ output: String) { self.output = output }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        calls.append(arguments)
        return .init(status: 0, stdout: Data(output.utf8))
    }
}

struct ManagedInspectionPerformanceTests {
    private let socket = "/private/tmp/perf-inspection-fixture.sock"
    private var pane: ManagedPane {
        .init(name: "zeus", id: "%0", socket: socket, serverPID: 1, sessionNumber: "0",
              pid: Int(getpid()), startTime: 0, dead: false)
    }
    private func output(owner: String = "fixture", member: String = "%0", name: String = "zeus") -> String {
        "S\t\(name)\t$0\t\(owner)\nP\t\(member)\nD\tzeus\t%0\t\(socket)\t1\t$0\t\(getpid())\t0\t\t\n"
    }
    private func host(_ runner: InspectionBatchRunner) -> ManagedTmux {
        .init(executable: URL(fileURLWithPath: "/bin/false"), runner: runner,
              environment: ["HOME": "/private/tmp/perf-inspection-home"], testSocket: socket)
    }
    @Test func knownPaneUsesOneClientAndKeepsAllThreeQueries() async throws {
        let runner = InspectionBatchRunner(output())
        let result = try #require(try await host(runner).inspect(name: "zeus", owner: "fixture", pane: pane))
        #expect(result.id == "%0" && result.pid == Int(getpid()) && result.startTime > 0)
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].filter { $0 == ";" }.count == 2)
        #expect(calls[0].contains("list-sessions") && calls[0].contains("list-panes") && calls[0].contains("display-message"))
    }
    @Test func batchCannotBypassOwnerExactSessionOrPaneMembership() async throws {
        do {
            _ = try await host(InspectionBatchRunner(output(owner: "someone-else"))).inspect(name: "zeus", owner: "fixture", pane: pane)
            Issue.record("A different owner was accepted")
        } catch ManagedSessionError.ownershipChanged { }
        #expect(try await host(InspectionBatchRunner(output(member: "%1"))).inspect(name: "zeus", owner: "fixture", pane: pane) == nil)
        #expect(try await host(InspectionBatchRunner(output(name: "zeus-other"))).inspect(name: "zeus", owner: "fixture", pane: pane) == nil)
        do {
            _ = try await host(InspectionBatchRunner(output() + "D\tduplicate\n")).inspect(name: "zeus", owner: "fixture", pane: pane)
            Issue.record("Duplicate metadata was accepted")
        } catch ManagedSessionError.ownershipChanged { }
    }
}
