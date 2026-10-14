import Foundation
import ZeusDesign
import SQLite3
import ZeusProtocol

/// Conversation identity is independent of the bridge's process lifetime and tmux pane ID.
struct ManagedConversation: Codable, Equatable, Sendable {
    var agent: AgentKind
    var folder: String
    var launchPrompt: String
    var nonce: String = UUID().uuidString
    var nativeID: String?
    var didLaunch = false
    var firstMessage: String { "Call zeus_say with a short greeting, then wait for the user. Zeus managed conversation: \(nonce) (internal marker; do not include it in your greeting)." }
}

/// An app-owned intent/lease. Persisted before starting a child; never contains credentials.
struct ManagedSessionRecord: Codable, Sendable {
    var version = 1
    var owner = UUID().uuidString
    var name: String?
    var pane: ManagedPane?
    /// Confirmed by a bridge with this owned pane and parent lifetime, never inferred from cwd.
    var confirmedSessionKey: String?
    var conversation: ManagedConversation?
    var restarts: [Date] = []
    var launchPending = false
    var pendingWasFresh = false
    /// Only native profile locations, never authentication material.
    var nativeEnvironment: [String: String] = [:]
    /// Exact preferences from the last successful launch; old records have no evidence.
    var appliedConfiguration: ManagedSessionConfig?
}

struct ManagedSessionStore: Sendable {
    let url: URL
    func load() throws -> ManagedSessionRecord {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let record = try JSONDecoder().decode(ManagedSessionRecord.self, from: Data(contentsOf: url))
        guard record.version == 1, UUID(uuidString: record.owner) != nil,
              record.name.map({ $0 == "zeus" || ($0.hasPrefix("zeus-") && Int($0.dropFirst(5)) != nil) }) ?? true else {
            throw ManagedSessionError.invalidState
        }
        guard record.nativeEnvironment.keys.allSatisfy({ ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"].contains($0) }),
              record.conversation.map({ UUID(uuidString: $0.nonce) != nil }) ?? true else { throw ManagedSessionError.invalidState }
        return record
    }
    func save(_ record: ManagedSessionRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Read-only native discovery must match Zeus's unique first message, never newest/cwd alone.
protocol ManagedConversationFinding: Sendable {
    func nativeID(for conversation: ManagedConversation, environment: [String: String]) async throws -> String?
}

struct NativeManagedConversationFinder: ManagedConversationFinding {
    func nativeID(for conversation: ManagedConversation, environment: [String: String]) async throws -> String? {
        try await Task.detached(priority: .utility) {
            let home = environment["HOME"] ?? NSHomeDirectory()
            switch conversation.agent {
            case .claude: return conversation.nonce
            case .codex:
                let root = environment["CODEX_HOME"] ?? home + "/.codex"
                let database = URL(fileURLWithPath: root).appendingPathComponent("state_5.sqlite")
                if FileManager.default.fileExists(atPath: database.path) {
                    do {
                        if let id = try Self.databaseID(database, sql: "SELECT id FROM threads WHERE first_user_message=? LIMIT 2", message: conversation.firstMessage, agent: .codex) { return id }
                    } catch ManagedSessionError.nativeStoreUnavailable {
                        // Older schemas and transient migrations can still use the literal CLI history.
                    }
                }
                let path = URL(fileURLWithPath: root).appendingPathComponent("history.jsonl")
                guard FileManager.default.fileExists(atPath: path.path) else { return nil }
                let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }
                let end = try file.seekToEnd(); let offset = end > 1_048_576 ? end - 1_048_576 : 0
                try file.seek(toOffset: offset)
                let data = try file.read(upToCount: 1_048_576) ?? Data()
                struct Entry: Decodable { var session_id: String; var text: String }
                var ids: Set<String> = []
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    guard let item = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), item.text == conversation.firstMessage,
                          UUID(uuidString: item.session_id) != nil else { continue }
                    ids.insert(item.session_id)
                }
                guard ids.count <= 1 else { throw ManagedSessionError.ambiguousConversation }
                return ids.first
            case .opencode:
                let root = environment["XDG_DATA_HOME"] ?? home + "/.local/share"
                let path = URL(fileURLWithPath: root).appendingPathComponent("opencode/opencode.db")
                guard FileManager.default.fileExists(atPath: path.path) else { return nil }
                // Join user messages so an assistant quoting the marker cannot claim ownership.
                return try Self.databaseID(path, sql: "SELECT DISTINCT p.session_id FROM part p JOIN message m ON m.id=p.message_id WHERE json_extract(m.data,'$.role')='user' AND json_extract(p.data,'$.type')='text' AND json_extract(p.data,'$.text')=? LIMIT 2", message: conversation.firstMessage, agent: .opencode)
            case .other: throw ManagedSessionError.unsupportedAgent
            }
        }.value
    }
    private static func databaseID(_ path: URL, sql: String, message: String, agent: AgentKind) throws -> String? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }; throw ManagedSessionError.nativeStoreUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ManagedSessionError.nativeStoreUnavailable }
        defer { sqlite3_finalize(statement) }
        return try message.withCString { text in
            guard sqlite3_bind_text(statement, 1, text, -1, nil) == SQLITE_OK else { throw ManagedSessionError.nativeStoreUnavailable }
            var ids: Set<String> = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw ManagedSessionError.nativeStoreUnavailable }
                let id = String(cString: raw)
                let valid = agent == .codex ? UUID(uuidString: id) != nil : id.hasPrefix("ses_") && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
                guard valid else { throw ManagedSessionError.invalidState }
                ids.insert(id)
            }
            guard ids.count <= 1 else { throw ManagedSessionError.ambiguousConversation }
            return ids.first
        }
    }

}

/// Managed-session failures are exposed in Settings without deleting native context or user sessions.
enum ManagedSessionError: Error, LocalizedError, Sendable {
    case invalidState, invalidPermission, unsupportedAgent, missingBridge, invalidFolder, ownershipChanged, collision, ambiguousConversation, nativeStoreUnavailable, missingNativeID
    case command(String), terminalCommand(String)
    var errorDescription: String? {
        switch self {
        case .invalidState: ZeusRuntimeCopy.Managed.invalidState
        case .invalidPermission: "Choose a supported permission mode for this agent."
        case .unsupportedAgent: "Choose Claude Code, Codex or OpenCode."
        case .missingBridge: ZeusRuntimeCopy.Managed.missingBridge
        case .invalidFolder: "Zeus can't find your assistant's folder. Choose it again in Settings → Assistant."
        case .ownershipChanged: ZeusRuntimeCopy.Managed.ownershipChanged
        case .collision: ZeusRuntimeCopy.Managed.nameTaken
        case .ambiguousConversation: ZeusRuntimeCopy.Managed.ambiguousConversation
        case .nativeStoreUnavailable: ZeusRuntimeCopy.Managed.conversationStoreUnreadable
        case .missingNativeID: ZeusRuntimeCopy.Managed.cantResume(agent: "Your assistant")
        case .terminalCommand: ZeusRuntimeCopy.Managed.terminalFailed
        case .command(let message): message
        }
    }
}
