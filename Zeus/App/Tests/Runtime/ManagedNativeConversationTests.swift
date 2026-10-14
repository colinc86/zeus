import Foundation
import SQLite3
import Testing
import ZeusProtocol
@testable import Zeus

struct ManagedNativeConversationTests {
    @Test func codexDiscoversOnlyUniqueManagedMarkerAndDoesNotWriteConfig() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = ManagedConversation(agent: .codex, folder: "/same/folder", launchPrompt: "instructions")
        let desired = UUID().uuidString, other = UUID().uuidString
        let path = folder.appendingPathComponent("history.jsonl")
        func line(_ id: String, _ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["session_id": id, "text": text]).addingNewline()
        }
        var data = Data(repeating: 120, count: 1_100_000); data.append(10)
        data += try line(other, "Other agent in the same folder")
        data += try line(desired, conversation.firstMessage)
        try data.write(to: path)
        let finder = NativeManagedConversationFinder()
        #expect(try await finder.nativeID(for: conversation, environment: ["CODEX_HOME": folder.path]) == desired)
        #expect(try Data(contentsOf: path) == data)
        data += try line(other, conversation.firstMessage); try data.write(to: path)
        await #expect(throws: (any Error).self) { try await finder.nativeID(for: conversation, environment: ["CODEX_HOME": folder.path]) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.toml").path))
    }

    @Test func openCodeReadOnlyDiscoveryMatchesUserPartNotFolderOrAssistantQuote() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-open-" + UUID().uuidString)
        let directory = folder.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = directory.appendingPathComponent("opencode.db")
        var database: OpaquePointer?
        guard sqlite3_open(path.path, &database) == SQLITE_OK, let database else { Issue.record("Couldn't make test DB"); return }
        defer { sqlite3_close(database) }
        func sql(_ text: String) throws {
            guard sqlite3_exec(database, text, nil, nil, nil) == SQLITE_OK else { throw ManagedSessionError.nativeStoreUnavailable }
        }
        try sql("CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT); CREATE TABLE part (message_id TEXT, session_id TEXT, data TEXT);")
        let conversation = ManagedConversation(agent: .opencode, folder: "/same/folder", launchPrompt: "instructions")
        func insert(_ id: String, role: String, session: String, text: String) throws {
            let message = String(decoding: try JSONSerialization.data(withJSONObject: ["role": role]), as: UTF8.self)
            let part = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "text", "text": text]), as: UTF8.self)
            func quoted(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "''") + "'" }
            try sql("INSERT INTO message VALUES (\(quoted(id)),\(quoted(message))); INSERT INTO part VALUES (\(quoted(id)),\(quoted(session)),\(quoted(part)));")
        }
        try insert("m1", role: "assistant", session: "ses_wrong", text: conversation.firstMessage)
        try insert("m2", role: "user", session: "ses_other", text: "Other session in same folder")
        try insert("m3", role: "user", session: "ses_managed", text: conversation.firstMessage)
        let before = try Data(contentsOf: path)
        let finder = NativeManagedConversationFinder()
        #expect(try await finder.nativeID(for: conversation, environment: ["XDG_DATA_HOME": folder.path]) == "ses_managed")
        #expect(try Data(contentsOf: path) == before)
        try insert("m4", role: "user", session: "ses_ambiguous", text: conversation.firstMessage)
        await #expect(throws: (any Error).self) { try await finder.nativeID(for: conversation, environment: ["XDG_DATA_HOME": folder.path]) }
    }
}
private extension Data {
    func addingNewline() -> Data { var value = self; value.append(10); return value }
}

extension ManagedNativeConversationTests {
    @Test func codexNativeDatabaseRecoversWhenCliHistoryIsDisabled() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-nohistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = ManagedConversation(agent: .codex, folder: "/same/folder", launchPrompt: "instructions")
        let nativeID = UUID().uuidString
        let path = folder.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(path.path, &database) == SQLITE_OK, let database else { Issue.record("Couldn't make test DB"); return }
        defer { sqlite3_close(database) }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let sql = "CREATE TABLE threads (id TEXT, first_user_message TEXT); INSERT INTO threads VALUES(\(quote(nativeID)),\(quote(conversation.firstMessage))); INSERT INTO threads VALUES(\(quote(UUID().uuidString)), 'Other conversation in same folder');"
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        let before = try Data(contentsOf: path)
        #expect(try await NativeManagedConversationFinder().nativeID(for: conversation, environment: ["CODEX_HOME": folder.path]) == nativeID)
        #expect(try Data(contentsOf: path) == before)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.jsonl").path))
    }
}
