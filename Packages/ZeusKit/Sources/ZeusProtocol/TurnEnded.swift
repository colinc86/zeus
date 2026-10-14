import Foundation

/// One process in the native hook's ancestry. Start time prevents PID reuse.
public struct HookProcessIdentity: Codable, Equatable, Sendable {
    /// Native process ID. Identity always includes its start time.
    public var pid: Int
    /// Process start in microseconds since the Unix epoch.
    public var startTime: UInt64
    /// Creates a lifetime identity captured from the operating system.
    public init(pid: Int, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

/// Stateless hook notification; never an MCP bridge registration or routing takeover.
/// Only identity and correlation metadata cross the socket, not transcript contents.
public struct TurnEnded: Codable, Equatable, Sendable {
    /// Native cause; all causes release implicit activity under the same guards.
    public enum Reason: String, Codable, Sendable { case completed, interrupted, error, sessionEnded, idle }
    /// Envelope compatibility version, checked before identity matching.
    public var wireVersion: Int
    /// Native backend emitting the signal.
    public var agent: AgentKind
    /// The short-lived notifier, not the MCP bridge.
    public var pid: Int
    /// Its immediate parent (which can be a hook shell).
    public var ppid: Int
    /// Native working directory; metadata only, never sufficient identity.
    public var cwd: String
    /// Bounded parent ancestry; a registered agent lifetime must match exactly.
    public var ancestors: [HookProcessIdentity]
    /// Hook invocation time in Unix seconds, captured before stdin/file/socket work.
    public var firedAt: Double
    /// Why the native agent stopped responding.
    public var reason: Reason
    /// Optional namespace metadata; never used to select a session.
    public var tmuxPane: String?
    /// Claude session, Codex thread or OpenCode conversation ID, when supplied.
    public var nativeSessionID: String?
    /// Present when the native turn's input contains a Zeus delivery envelope.
    public var deliveryID: String?
    /// Creates one stateless, best-effort completion notification.
    public init(agent: AgentKind, pid: Int, ppid: Int, cwd: String, ancestors: [HookProcessIdentity], firedAt: Double,
                reason: Reason = .completed, tmuxPane: String? = nil, nativeSessionID: String? = nil, deliveryID: String? = nil,
                wireVersion: Int = ZeusProtocol.wireVersion) {
        self.wireVersion = wireVersion; self.agent = agent; self.pid = pid; self.ppid = ppid; self.cwd = cwd
        self.ancestors = ancestors; self.firedAt = firedAt; self.reason = reason; self.tmuxPane = tmuxPane
        self.nativeSessionID = nativeSessionID; self.deliveryID = deliveryID
    }
}

/// A one-shot request has reached the app delegate. No MCP consumption or delivery ack is implied.
public struct TurnEndedReceipt: Codable, Equatable, Sendable {
    /// Creates an empty receipt. It does not acknowledge a user delivery.
    public init() {}
}
