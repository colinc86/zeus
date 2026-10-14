import Darwin
import Foundation
import ZeusLink
import ZeusProtocol

/// Reads a native hook's metadata and sends only its identity/correlation signal.
/// Failures are best-effort: no stdout, permission decision, retry or saved settings.
public enum NativeTurnHook {
    /// Consumes the native event on stdin/final argv and exits without MCP output.
    public static func run(options: MCPCommandLineOptions, firedAt: Double) async {
        let data = options.hookPayload.map { Data($0.utf8) } ?? FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 256 * 1024, let input = try? ZeusJSON.decoder().decode(JSONValue.self, from: data) else { return }
        let source: String?
        if options.agent == .claude, case .string(let path)? = input["transcript_path"] { source = latestClaudeInput(path: path, promptID: string(input["prompt_id"])) }
        else { source = nil }
        guard let event = event(agent: options.agent, input: input, firedAt: firedAt, pid: Int(getpid()), ppid: Int(getppid()),
                                ancestors: AgentProcessIdentity.ancestors(pid: Int(getppid())), cwd: FileManager.default.currentDirectoryPath,
                                environment: ProcessInfo.processInfo.environment, claudeInput: source) else { return }
        try? await TurnEndedClient.send(event, socketPath: options.socketPath)
    }

    /// Reduces a supported native event to identity/time and optional delivery ID.
    public static func event(agent: AgentKind, input: JSONValue, firedAt: Double, pid: Int, ppid: Int,
                             ancestors: [HookProcessIdentity], cwd: String, environment: [String: String], claudeInput: String? = nil) -> TurnEnded? {
        let reason: TurnEnded.Reason, session: String?, source: String?
        switch agent {
        case .claude:
            switch input["hook_event_name"] {
            case "Stop": reason = .completed
            case "StopFailure": reason = .error
            case "SessionEnd": reason = .sessionEnded
            case "Notification":
                guard input["notification_type"] == "idle_prompt" else { return nil }
                reason = .idle
            default: return nil
            }
            session = string(input["session_id"]); source = claudeInput
        case .codex:
            guard input["type"] == "agent-turn-complete" else { return nil }
            reason = .completed; session = string(input["thread-id"])
            if case .array(let messages)? = input["input-messages"] { source = messages.compactMap { string($0) }.last }
            else { source = nil }
        case .opencode:
            guard input["type"] == "session.idle" || input["type"] == "session.error" else { return nil }
            reason = input["type"] == "session.error" ? .error : .completed
            session = string(input["sessionID"]); source = string(input["input"])
        case .other: return nil
        }
        let at: Double
        if case .number(let time)? = input["firedAt"], time.isFinite { at = time } else { at = firedAt }
        return .init(agent: agent, pid: pid, ppid: ppid, cwd: string(input["cwd"]) ?? cwd, ancestors: ancestors,
                     firedAt: at, reason: reason, tmuxPane: environment["TMUX_PANE"], nativeSessionID: session,
                     deliveryID: source.flatMap(deliveryID))
    }

    /// Stops at the most recent actual user text in the hook's prompt. Claude may
    /// invoke Stop before flushing that prompt to disk; never borrow an older ID.
    /// Tool-result user frames are not new turns. The read is bounded to 1 MiB.
    public static func latestClaudeInput(path: String, promptID: String? = nil) -> String? {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd(), (try? file.seek(toOffset: size > 1_048_576 ? size - 1_048_576 : 0)) != nil,
              let data = try? file.readToEnd() else { return nil }
        for line in data.split(separator: 10).reversed() {
            guard let frame = try? ZeusJSON.decoder().decode(JSONValue.self, from: Data(line)), frame["type"] == "user",
                  let message = frame["message"], message["role"] == "user" else { continue }
            if let promptID, frame["promptId"] != .string(promptID) { continue }
            if let text = string(message["content"]), !text.isEmpty { return text }
            if case .array(let parts)? = message["content"] {
                // A synchronous Zeus answer/skipped result begins its own response.
                // It is not the older user envelope that originally asked the question.
                if parts.contains(where: { part in
                    guard part["type"] == "tool_result" else { return false }
                    let text: String
                    if let value = string(part["content"]) { text = value }
                    else if case .array(let blocks)? = part["content"] { text = blocks.compactMap { string($0["text"]) }.joined(separator: "\n") }
                    else { return false }
                    guard let first = text.split(separator: "\n").first, let result = try? ZeusJSON.decoder().decode(JSONValue.self, from: Data(first.utf8)) else { return false }
                    return result["card_id"] != nil && (result["status"] == "answered" || result["status"] == "skipped")
                }) { return nil }
                let text = parts.filter { $0["type"] == "text" }.compactMap { string($0["text"]) }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// Extracts only the last Zeus envelope ID; user text is never forwarded.
    public static func deliveryID(_ text: String) -> String? {
        for pattern in ["\\[zeus delivery_id=([^\\s\\]]+)", "delivery_id=[\"']([^\"']+)[\"']"] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }
    private static func string(_ value: JSONValue?) -> String? { if case .string(let text) = value { return text }; return nil }
}
