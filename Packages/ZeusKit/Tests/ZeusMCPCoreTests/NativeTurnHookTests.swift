import Foundation
import Testing
import ZeusProtocol
@testable import ZeusMCPCore

struct NativeTurnHookTests {
    private func event(_ input: JSONValue, agent: AgentKind = .claude, source: String? = nil) -> TurnEnded? {
        NativeTurnHook.event(agent: agent, input: input, firedAt: 123, pid: 3, ppid: 2,
            ancestors: [.init(pid: 2, startTime: 1)], cwd: "/fixture", environment: ["TMUX_PANE": "%0"], claudeInput: source)
    }
    @Test func nativeInputsAreReducedToCorrelationNotUserText() throws {
        let value = try #require(event(["hook_event_name": "Stop", "session_id": "native", "transcript_path": "/unused"], source: "[zeus delivery_id=d_1] Private fixture text"))
        #expect(value.deliveryID == "d_1" && value.nativeSessionID == "native" && value.reason == .completed)
        #expect(!String(decoding: try ZeusJSON.encoder().encode(value), as: UTF8.self).contains("Private fixture text"))
        #expect(event(["hook_event_name": "StopFailure"])?.reason == .error)
        #expect(event(["hook_event_name": "Notification", "notification_type": "permission_prompt"]) == nil)
        #expect(event(["hook_event_name": "Notification", "notification_type": "idle_prompt"])?.reason == .idle)
        #expect(event(["type": "agent-turn-complete", "thread-id": "native", "input-messages": ["[zeus delivery_id=d_2] Hi"]], agent: .codex)?.deliveryID == "d_2")
        #expect(event(["type": "session.idle", "sessionID": "native", "input": "[zeus delivery_id=d_3] Hi", "firedAt": 12], agent: .opencode)?.firedAt == 12)
    }
    @Test func cliHookModesNeverTreatPayloadAsMCPConfiguration() throws {
        let options = try MCPCommandLineOptions.parse(["--turn-ended", "--agent", "codex", "--socket", "/fixture/socket", "{\"type\":\"agent-turn-complete\"}"])
        #expect(options.turnEnded && options.hookPayload != nil)
        #expect(throws: MCPCommandLineError.self) { try MCPCommandLineOptions.parse(["{\"type\":\"agent-turn-complete\"}"]) }
        #expect(throws: MCPCommandLineError.self) { try MCPCommandLineOptions.parse(["--turn-ended", "--hook-settings"]) }
    }
    @Test func transcriptSkipsToolResultsButNeverFallsBackPastANewerUserTurn() throws {
        let file = URL(fileURLWithPath: "/tmp/ztranscript_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let old: JSONValue = ["type": "user", "message": ["role": "user", "content": "[zeus delivery_id=d_old] Hi"]]
        let tool: JSONValue = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "Shell result"]]]]
        func write(_ frames: [JSONValue]) throws {
            try frames.reduce(into: Data()) { data, frame in data.append(try ZeusJSON.encoder().encode(frame)); data.append(10) }.write(to: file)
        }
        try write([old, tool]); #expect(NativeTurnHook.latestClaudeInput(path: file.path, promptID: "new-not-flushed") == nil)
        #expect(NativeTurnHook.latestClaudeInput(path: file.path)?.contains("d_old") == true)
        try write([old, tool, ["type": "user", "message": ["role": "user", "content": "New human prompt"]]])
        #expect(NativeTurnHook.latestClaudeInput(path: file.path) == "New human prompt")
        let answer: JSONValue = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "{\"status\":\"answered\",\"card_id\":\"c_1\"}"]]]]
        try write([old, answer, tool]); #expect(NativeTurnHook.latestClaudeInput(path: file.path) == nil)
    }
    @Test func openCodeConfigCreatesOnlyAnOwnedContentAddressedFile() throws {
        let root = URL(fileURLWithPath: "/tmp/zplugin_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try OpenCodeHookSettings.make(bridgePath: "/fixture/bridge", socketPath: "/fixture/socket", directory: root)
        #expect(try OpenCodeHookSettings.make(bridgePath: "/fixture/bridge", socketPath: "/fixture/socket", directory: root) == a)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }
}
