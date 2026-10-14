import Foundation
import ZeusProtocol

/// Absolute CLI discovery, including user-local installs missing from a GUI's PATH.
struct ManagedExecutables: Sendable {
    var tmux: URL?
    var agents: [AgentKind: URL]
    static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let directories = [home + "/.local/bin", home + "/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        func find(_ name: String) -> URL? {
            directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return .init(tmux: TmuxExecutable.resolve(environment: environment), agents: [.claude, .codex, .opencode].reduce(into: [:]) { $0[$1] = find($1.rawValue) })
    }
}

/// The immutable argument vector handed to tmux; environment assignments contain no copied secrets.
struct ManagedLaunchCommand: Sendable {
    var arguments: [String]
}

/// Closed Settings choices, with exact argument mappings. IDs are persisted, never display titles.
@MainActor
enum ManagedAgentLaunch {
    struct Policy {
        let mode: ManagedPermissionMode
        let arguments: [String]
        var openCodePermission: String? = nil
    }
    static func policies(for agent: AgentKind) -> [Policy] {
        func p(_ id: String, _ title: String, _ detail: String, _ args: [String], unrestricted: Bool = false, normal: Bool = false, permission: String? = nil) -> Policy {
            .init(mode: .init(id: id, title: title, detail: detail, isUnrestricted: unrestricted, isDefault: normal), arguments: args, openCodePermission: permission)
        }
        switch agent {
        case .claude:
            return [
                p("manual", "Ask first", "Asks before editing files or running commands.", ["--permission-mode", "manual"], normal: true),
                p("plan", "Plan only", "Looks around and proposes a plan; asks before acting on it.", ["--permission-mode", "plan"]),
                p("dontAsk", "Never ask", "Does only what you've already allowed; refuses the rest without asking.", ["--permission-mode", "dontAsk"]),
                p("acceptEdits", "Accept edits", "Edits files without asking; asks before other commands.", ["--permission-mode", "acceptEdits"]),
                p("auto", "Auto", "A safety check approves routine actions; asks about the rest. Some models fall back to Ask first.", ["--permission-mode", "auto"]),
                p("bypassPermissions", "Bypass permissions", "Never asks. It can run any command and change any file you can. Confirm once in Terminal the first time.", ["--dangerously-skip-permissions"], unrestricted: true)
            ]
        case .codex:
            return [
                p("workspace-write/on-request", "Ask when needed", "Works in this folder; asks before going outside it.", ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"], normal: true),
                p("read-only/on-request", "Read only", "Reads files but doesn't change them; asks before anything more.", ["--sandbox", "read-only", "--ask-for-approval", "on-request"]),
                p("approve-for-me", "Approve for me", "Works in this folder; a safety check answers its requests for you.", ["--approve-for-me"]),
                p("danger-full-access/on-request", "Full access", "No sandbox: it can change any file you can. Still asks before risky commands.", ["--sandbox", "danger-full-access", "--ask-for-approval", "on-request"]),
                p("yolo", "YOLO", "No sandbox and no approvals at all. It can run any command and change any file you can.", ["--dangerously-bypass-approvals-and-sandbox"], unrestricted: true)
            ]
        case .opencode:
            return [
                p("ask", "Ask", "Asks before using a tool you haven't allowed. Your own permission rules still apply.", [], normal: true, permission: "ask"),
                p("deny", "Deny", "Refuses any tool you haven't allowed, without asking.", [], permission: "deny"),
                p("allow", "Allow all", "Uses any tool you haven't denied, without asking.", [], unrestricted: true, permission: "allow"),
                p("auto", "Auto", "Approves every request by itself; only tools you've denied are refused.", ["--auto"], unrestricted: true)
            ]
        case .other: return []
        }
    }

    /// Writes only Zeus-owned injection artifacts. User config, plugins and instructions stay enabled.
    static func command(conversation: ManagedConversation, permissionID: String?, executable: URL,
                        bridge: URL, socket: String, pane: ManagedPane, directory: URL,
                        environment: [String: String], systemPromptSnapshotOff: Bool = false) throws -> ManagedLaunchCommand {
        let policies = policies(for: conversation.agent)
        let id = permissionID == "default" && conversation.agent == .claude ? "manual" : permissionID
        guard let policy = id.map({ id in policies.first { $0.mode.id == id } }) ?? policies.first(where: { $0.mode.isDefault }) else {
            throw ManagedSessionError.invalidPermission
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func write(_ name: String, _ data: Data) throws -> String {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        func string(_ value: String) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let mcp: [String: JSONValue] = ["command": .string(bridge.path), "args": ["--agent", .string(conversation.agent.rawValue), "--socket", .string(socket)]]
        var args = [executable.path]
        switch conversation.agent {
        case .claude:
            let path = try write("claude-mcp.json", encoder.encode(JSONValue.object(["mcpServers": ["zeus": .object(mcp)]])))
            let allowed = ZeusMCP.tools.map { "mcp__zeus__" + $0.name }.joined(separator: ",")
            // Claude 2.1.296's channel-name check excludes launch-only MCP
            // configs. Keep this injection local and use the verified tmux route;
            // do not impose a consent warning for a channel that cannot register.
            args += ["--mcp-config", path, "--append-system-prompt", conversation.launchPrompt,
                     "--allowedTools", allowed] + policy.arguments
            if systemPromptSnapshotOff { args += ["--system-prompt-snapshot", "off"] }
            if conversation.didLaunch, let id = conversation.nativeID { args += ["--resume", id] } else { args += ["--session-id", conversation.nonce, conversation.firstMessage] }
        case .codex:
            let location = pane.socket + ",\(pane.serverPID),\(pane.sessionNumber)"
            let tools = try ZeusMCP.tools.map { "\(try string($0.name))={approval_mode=\(try string("approve"))}" }.joined(separator: ",")
            let table = "mcp_servers.zeus={command=\(try string(bridge.path)),args=[\(try string("--agent")),\(try string("codex")),\(try string("--socket")),\(try string(socket))],env={TMUX_PANE=\(try string(pane.id)),TMUX=\(try string(location))},tools={\(tools)}}"
            args += ["--no-daemon", "-c", table, "-c", "developer_instructions=" + (try string(conversation.launchPrompt))] + policy.arguments
            if let id = conversation.nativeID { args += ["resume", id] } else { args += [conversation.firstMessage] }
        case .opencode:
            let instructions = try write("opencode-instructions.txt", Data(conversation.launchPrompt.utf8))
            var fields: [String: JSONValue] = ["mcp": ["zeus": ["type": "local", "command": .array([.string(bridge.path), "--agent", "opencode", "--socket", .string(socket)]), "enabled": true]], "instructions": [.string(instructions)], "experimental": ["disable_paste_summary": true]]
            var permissions = ZeusMCP.tools.reduce(into: [String: JSONValue]()) { $0["zeus_" + $1.name] = "allow" }
            if let permission = policy.openCodePermission { permissions["*"] = .string(permission) }
            fields["permission"] = .object(permissions)
            args += [conversation.folder] + policy.arguments
            // Inline config is merged with the user's setup; no --pure and no registration writes.
            let content = String(decoding: try encoder.encode(JSONValue.object(fields)), as: UTF8.self)
            args = ["OPENCODE_CONFIG_CONTENT=" + content] + args
            if let id = conversation.nativeID { args += ["--session", id] } else { args += ["--prompt", conversation.firstMessage] }
        case .other: throw ManagedSessionError.unsupportedAgent
        }
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        paths += [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen: Set<String> = []; paths = paths.filter { seen.insert($0).inserted }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let profiles = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"].compactMap { key in environment[key].map { key + "=" + $0 } }
        return .init(arguments: ["/usr/bin/env", "HOME=" + home, "PATH=" + paths.joined(separator: ":"), "LANG=en_US.UTF-8", "LC_CTYPE=UTF-8", "LC_ALL=en_US.UTF-8", "TERM=xterm-256color"] + profiles + args)
    }
}
