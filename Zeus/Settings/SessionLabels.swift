import Foundation
import ZeusProtocol

/// Presentation only: routing always uses the original, complete session key.
enum SessionLabels {
    struct ProcessIdentity: Equatable {
        let pid: Int32
        let startedAt: Date
    }

    static func identity(for session: ConnectedSession) -> ProcessIdentity? {
        // Match the known cwd rather than splitting on '#': directory names may contain it.
        let prefix = "\(session.agent.rawValue):\(session.cwd)#"
        guard session.sessionKey.hasPrefix(prefix) else { return nil }
        let parts = session.sessionKey.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let pid = Int32(parts[0]), pid > 0, let start = UInt64(parts[1]), start > 0 else { return nil }
        return ProcessIdentity(pid: pid, startedAt: Date(timeIntervalSince1970: Double(start) / 1_000_000))
    }

    static func label(for session: ConnectedSession) -> String {
        let agent: String = switch session.agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .other: "Other"
        }
        let folders = session.cwd.split(separator: "/").suffix(2).joined(separator: "/")
        let location = folders.isEmpty ? session.cwd : folders
        if let process = identity(for: session) {
            return "\(agent) · \(location) · pid \(process.pid) · started \(process.startedAt.formatted(date: .omitted, time: .shortened))"
        }
        // Preview/legacy keys lack process identity; do not mistake a tmux pane for a PID.
        return "\(agent) · \(location) · connected \(session.connectedAt.formatted(date: .omitted, time: .shortened))"
    }

    static func agentName(_ agent: AgentKind) -> String {
        switch agent { case .claude: "Claude"; case .codex: "Codex"; case .opencode: "OpenCode"; case .other: "Other" }
    }

    /// Stateless fallback for fixtures; the app uses its persisted lifetime registry.
    static func displayLabel(key: String, sessions: [ConnectedSession]) -> String {
        var registry = SessionLabelRegistry()
        registry.sync(sessions)
        return registry.label(key)
    }

    static func processCaption(for session: ConnectedSession) -> String {
        let connected = "connected " + session.connectedAt.formatted(date: .omitted, time: .shortened)
        guard let identity = identity(for: session) else { return connected }
        return "pid \(identity.pid) · started \(identity.startedAt.formatted(date: .omitted, time: .shortened)) · " + connected
    }

    static func unique(_ sessions: [ConnectedSession]) -> [ConnectedSession] {
        var keys: Set<String> = []
        return sessions.filter { keys.insert($0.sessionKey).inserted }
    }
}

/// Retains public labels after disconnect/relaunch; routing always retains the complete key.
struct SessionLabelRegistry: Codable, Equatable {
    struct Record: Codable, Equatable {
        let agent: AgentKind
        let cwd: String
        let ordinal: Int
        var parent = false
    }
    private(set) var records: [String: Record] = [:]

    mutating func sync(_ sessions: [ConnectedSession]) {
        let live = SessionLabels.unique(sessions).sorted {
            $0.connectedAt == $1.connectedAt ? $0.sessionKey < $1.sessionKey : $0.connectedAt < $1.connectedAt
        }
        for session in live where records[session.sessionKey] == nil {
            // Disconnected bridges can reconnect with the same process key. Reserve their
            // ordinals while their history remains, so two living sessions never reclaim one.
            let used = Set(records.values.filter { $0.agent == session.agent && $0.cwd == session.cwd }.map(\.ordinal))
            let ordinal = (1...).first { !used.contains($0) } ?? 1
            records[session.sessionKey] = Record(agent: session.agent, cwd: session.cwd, ordinal: ordinal)
        }
        for session in live {
            if live.contains(where: { $0.agent == session.agent && $0.cwd != session.cwd && Self.folder($0.cwd) == Self.folder(session.cwd) }) {
                records[session.sessionKey]?.parent = true
            }
        }
    }

    mutating func retain(_ keys: Set<String>) { records = records.filter { keys.contains($0.key) } }

    func label(_ key: String) -> String {
        guard let record = records[key] ?? Self.fallback(key) else { return "Agent session" }
        let parts = record.cwd.split(separator: "/")
        // Compare retained history too: a disconnected destination still needs a unique label.
        let others = records.values.filter { $0.agent == record.agent && $0.cwd != record.cwd }
        var depth = min(parts.count, record.parent ? 2 : 1)
        while depth < parts.count && others.contains(where: {
            $0.cwd.split(separator: "/").suffix(depth).elementsEqual(parts.suffix(depth))
        }) { depth += 1 }
        var folder = parts.suffix(depth).joined(separator: "/")
        // A complete shorter path may itself be a suffix of another path.
        if others.contains(where: { $0.cwd.split(separator: "/").suffix(depth).elementsEqual(parts.suffix(depth)) }) {
            folder = record.cwd
        }
        var label = SessionLabels.agentName(record.agent) + " · " + (folder.isEmpty ? record.cwd : folder)
        if record.ordinal > 1 { label += " · \(record.ordinal)" }
        if let pane = Self.legacyPane(key) { label += " · pane \(pane)" }
        return label
    }

    /// Legacy keys retain only validated pane IDs; process identities never become UI text.
    private static func legacyPane(_ key: String) -> String? {
        guard let suffix = key.split(separator: "#").last, suffix.hasPrefix("%"),
              !suffix.dropFirst().isEmpty, suffix.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(suffix.dropFirst())
    }
    private static func fallback(_ key: String) -> Record? {
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let agent = AgentKind(rawValue: String(parts[0])), parts[1].hasPrefix("/") else { return nil }
        var cwd = String(parts[1])
        if let hash = cwd.lastIndex(of: "#") {
            let suffix = cwd[cwd.index(after: hash)...]
            let identity = suffix.split(separator: ".", omittingEmptySubsequences: false)
            if legacyPane(key) != nil || (identity.count == 2 && identity.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })) {
                cwd = String(cwd[..<hash])
            }
        }
        return Record(agent: agent, cwd: cwd, ordinal: 1)
    }
    private static func folder(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
}
