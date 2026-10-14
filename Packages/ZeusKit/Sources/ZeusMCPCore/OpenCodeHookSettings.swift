import CryptoKit
import Foundation
import ZeusProtocol

/// Creates a content-addressed plugin under Zeus's own support directory, never
/// in the agent's profile/project. The returned JSON is supplied only at launch.
public enum OpenCodeHookSettings {
    /// Returns a file-URL plugin setting after atomically writing its owned module.
    public static func make(bridgePath: String, socketPath: String, directory: URL) throws -> JSONValue {
        let text = try AgentTurnHooks.openCodePlugin(bridgePath: bridgePath, socketPath: socketPath)
        let bytes = Data(text.utf8), digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("opencode-\(digest).mjs")
        if (try? Data(contentsOf: file)) != bytes { try bytes.write(to: file, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return ["plugin": [.string(file.absoluteString)]]
    }
}
