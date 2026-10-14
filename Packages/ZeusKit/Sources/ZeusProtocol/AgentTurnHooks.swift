import Foundation

/// Session-only native completion wiring shared by managed and copyable launches.
/// No agent configuration file is written or disabled by this builder.
public enum AgentTurnHooks {
    /// Quotes a literal path for native command hooks and copied shell commands.
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Additive per-launch Claude hooks; no permissions or saved settings change.
    public static func claudeSettings(bridgePath: String, socketPath: String) throws -> String {
        let command = shellQuote(bridgePath) + " --turn-ended --agent claude --socket " + shellQuote(socketPath)
        let handler: JSONValue = ["type": "command", "command": .string(command), "timeout": .number(1.5)]
        let group: JSONValue = ["hooks": [handler]]
        let object: JSONValue = ["hooks": ["Stop": [group], "StopFailure": [group], "SessionEnd": [group],
            "Notification": [["matcher": "idle_prompt", "hooks": [handler]]]]]
        let encoder = ZeusJSON.encoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(object), as: UTF8.self)
    }

    /// Codex appends its event JSON as the final argv member, never shell text.
    public static func codexNotify(bridgePath: String, socketPath: String) throws -> String {
        String(decoding: try ZeusJSON.encoder().encode([bridgePath, "--turn-ended", "--agent", "codex", "--socket", socketPath]), as: UTF8.self)
    }

    /// No SDK/npm dependency. OpenCode loads this generated Zeus-owned module
    /// through its launch-only config, adding to the user's plugin list.
    public static func openCodePlugin(bridgePath: String, socketPath: String) throws -> String {
        func json(_ value: String) throws -> String { String(decoding: try ZeusJSON.encoder().encode(value), as: UTF8.self) }
        return """
        import { execFile } from "node:child_process";
        export const ZeusTurnEnded = async ({ client, directory }) => ({
          event: async ({ event }) => {
            if (event.type !== "session.idle" && event.type !== "session.error") return;
            const firedAt = Date.now() / 1000;
            const sessionID = event.properties?.sessionID;
            if (!sessionID) return;
            try {
              const result = await client.session.messages({ path: { id: sessionID } });
              const messages = result.data ?? [];
              const ended = event.type === "session.idle"
                ? messages.filter(m => m.info?.role === "assistant" && m.info?.time?.completed).at(-1) : undefined;
              const user = ended ? messages.find(m => m.info?.id === ended.info.parentID)
                : messages.filter(m => m.info?.role === "user").at(-1);
              const input = (user?.parts ?? []).filter(p => p.type === "text").map(p => p.text).join("\\n");
              const at = ended ? Math.min(firedAt, ended.info.time.completed / 1000) : firedAt;
              const payload = JSON.stringify({ type: event.type, sessionID, cwd: directory, input, firedAt: at });
              execFile(\(try json(bridgePath)), ["--turn-ended", "--agent", "opencode", "--socket", \(try json(socketPath)), payload],
                { timeout: 1500 }, () => {});
            } catch { /* Never changes native permissions, output or turn state. */ }
          }
        });
        """
    }
}
