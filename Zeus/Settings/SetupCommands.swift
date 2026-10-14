import Foundation

/// Copyable commands quote the executable as shell data; OpenCode uses JSON encoding.
enum SetupCommands {
    static var embeddedBridgeURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "zeus-mcp") }

    static func configuration(for backend: AssistantBackend, bridgePath: String) -> String {
        switch backend {
        case .claude: return "claude mcp add -s user zeus -- \(shellQuote(bridgePath)) --agent claude"
        case .codex: return "codex mcp add zeus -- \(shellQuote(bridgePath)) --agent codex"
        case .opencode:
            let object: [String: Any] = ["mcp": ["zeus": ["type": "local", "command": [bridgePath, "--agent", "opencode"], "enabled": true]]]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    static let claudeLaunch = "claude --dangerously-load-development-channels server:zeus"

    struct Step: Identifiable {
        let title: String
        let detail: String
        let command: String?
        var id: String { title }
    }
    static func steps(for backend: AssistantBackend) -> [Step] {
        let prerequisite: String = switch backend {
        case .claude: "Install Claude Code and sign in. Then, in Terminal, go to the folder your assistant works in and run this once:"
        case .codex: "Install Codex and tmux, and sign in to Codex. Then, in Terminal, go to the folder your assistant works in and run this once:"
        case .opencode: "Install OpenCode and set up a model provider. Add this block to opencode.json in your assistant's folder (or ~/.config/opencode/opencode.json for every folder), keeping your other settings:"
        }
        let launch: String = switch backend {
        case .claude: claudeLaunch
        case .codex: "tmux new-session -s codex codex"
        case .opencode: "opencode --port 4096 --hostname 127.0.0.1"
        }
        let routing: String = switch backend {
        case .claude: "The --dangerously-load-development-channels flag only lets Claude Code receive your Zeus messages. Claude asks once whether to load Zeus's channel: choose Yes. Then pick the session above, or leave Auto."
        case .codex: "Set How Zeus reaches it to Its Terminal pane, refresh the list and choose the pane running Codex. Then pick its session above. Zeus never types over text you haven't sent."
        case .opencode: "Set the server URL to http://127.0.0.1:4096 and choose the OpenCode conversation that should get your messages. If your server has a password, save it in the password field above."
        }
        return [Step(title: "1. Add Zeus to your agent", detail: prerequisite, command: nil),
                Step(title: "2. Start your agent", detail: "With Zeus running, start your agent in Terminal like this:", command: launch),
                Step(title: "3. Choose how Zeus reaches it", detail: routing, command: nil),
                Step(title: "4. Say hello", detail: "Your session should appear above. Ask your agent to say hi through Zeus, then send a test message. If it says it's waiting, the message is saved but not received yet. If no session appears, run step 1 again and restart your agent.", command: nil)]
    }
    static func guide(bridgePath: String) -> String {
        AssistantBackend.allCases.map { backend in
            backend.name + "\n\n" + configuration(for: backend, bridgePath: bridgePath) + "\n\n" +
                steps(for: backend).map { $0.title + "\n" + $0.detail + ($0.command.map { "\n" + $0 } ?? "") }.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
