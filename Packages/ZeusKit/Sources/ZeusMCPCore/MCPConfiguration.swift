import Darwin
import Foundation
import ZeusProtocol

/// Per-process metadata and socket configuration for the stdio MCP bridge.
public struct MCPConfiguration: Sendable {
    /// Agent backend. Only Claude advertises and emits channel notifications.
    public var agent: AgentKind
    /// Unix socket listened to by Zeus.app.
    public var socketPath: String
    /// Bridge process UUID, retained across reconnects.
    public var bridgeID: UUID
    /// Session working directory, used verbatim in the routing key.
    public var cwd: String
    /// Bridge process ID.
    public var pid: Int
    /// Parent process ID.
    public var ppid: Int
    /// Launching agent's start time in microseconds since Unix epoch; captured once per bridge.
    public var parentStartTime: UInt64
    /// Optional TMUX_PANE value for connector metadata; never part of session identity.
    public var tmuxPane: String?
    /// TMUX server namespace, independent of the agent process identity.
    public var tmuxSocketPath: String?
    /// Extracts the socket path, preserving commas in the path itself.
    public static func tmuxSocket(environment: String?) -> String? {
        guard let environment else { return nil }
        let parts = environment.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3, Int(parts[parts.count - 2]) != nil, Int(parts[parts.count - 1]) != nil else { return nil }
        let path = parts.dropLast(2).joined(separator: ",")
        return path.hasPrefix("/") && !path.utf8.contains(0) ? path : nil
    }
    /// Version reported in initialize.serverInfo.
    public var version: String
    /// Maximum size of one stdin JSON frame, excluding the newline.
    public var maximumFrameBytes: Int

    /// Creates configuration from the current process, with overrides for embedding and tests.
    public init(agent: AgentKind = .claude, socketPath: String = ZeusPaths.bridgeSocket.path,
                bridgeID: UUID = UUID(), cwd: String = FileManager.default.currentDirectoryPath,
                pid: Int = Int(getpid()), ppid: Int = Int(getppid()),
                tmuxPane: String? = ProcessInfo.processInfo.environment["TMUX_PANE"],
                version: String = MCPReleaseVersion.current, maximumFrameBytes: Int = 4 * 1024 * 1024,
                parentStartTime: UInt64? = nil,
                tmuxSocketPath: String? = MCPConfiguration.tmuxSocket(environment: ProcessInfo.processInfo.environment["TMUX"])) {
        self.agent = agent; self.socketPath = socketPath; self.bridgeID = bridgeID
        self.cwd = cwd; self.pid = pid; self.ppid = ppid; self.tmuxPane = tmuxPane
        self.tmuxSocketPath = tmuxSocketPath
        self.parentStartTime = parentStartTime ?? AgentProcessIdentity.startTime(pid: ppid) ?? 0
        self.version = version; self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    internal func hello(client: BridgeHello.Client) -> BridgeHello {
        .init(bridgeID: bridgeID, agent: agent, pid: pid, ppid: ppid, cwd: cwd, client: client,
              capabilities: .init(channel: agent == .claude, toolResultWritten: true, learningNotifications: agent == .claude), tmuxPane: tmuxPane, parentStartTime: parentStartTime, tmuxSocketPath: tmuxSocketPath)
    }
}

/// Parsed flags for the thin zeus-mcp executable. No persistent configuration is changed.
public struct MCPCommandLineOptions: Sendable, Equatable {
    /// Agent backend, defaulting to Claude.
    public var agent: AgentKind = .claude
    /// Socket path, defaulting to ZeusPaths.bridgeSocket.path.
    public var socketPath: String = ZeusPaths.bridgeSocket.path
    /// Whether help was requested; usage is printed to stderr to keep stdout protocol-only.
    public var showHelp = false
    /// Usage printed for --help and invalid arguments.
    public static let usage = "Usage: zeus-mcp [--agent claude|codex|opencode|other] [--socket PATH]"

    /// Parses arguments excluding argv[0]. Invalid or missing flag values throw.
    public static func parse(_ arguments: [String]) throws -> Self {
        var options = Self()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--help", "-h": options.showHelp = true
            case "--agent", "--socket":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--"), !arguments[index].isEmpty else {
                    throw MCPCommandLineError.invalidArgument("Missing value for \(flag)")
                }
                let value = arguments[index]
                if flag == "--agent" {
                    guard let agent = AgentKind(rawValue: value) else { throw MCPCommandLineError.invalidArgument("Unknown agent: \(value)") }
                    options.agent = agent
                } else {
                    guard !value.utf8.contains(0) else { throw MCPCommandLineError.invalidArgument("Socket path contains NUL") }
                    options.socketPath = (value as NSString).expandingTildeInPath
                }
            default: throw MCPCommandLineError.invalidArgument("Unknown argument: \(flag)")
            }
            index += 1
        }
        return options
    }
}

/// A command-line validation error, suitable for stderr.
public enum MCPCommandLineError: Error, Sendable, LocalizedError {
    case invalidArgument(String)
    public var errorDescription: String? { switch self { case .invalidArgument(let message): message } }
}
