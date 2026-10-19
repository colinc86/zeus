import CryptoKit
import Foundation
import Security
import LocalAuthentication

/// Synchronous so the guarded capture-to-commit main-actor turn cannot yield. Tests inject fixed bytes.
@MainActor protocol JournalKeyProviding: AnyObject {
    func key() throws -> Data
    var requiresProtectedFiles: Bool { get }
}
extension JournalKeyProviding { var requiresProtectedFiles: Bool { true } }
@MainActor final class KeychainJournalKeyProvider: JournalKeyProviding {
    private let account: String
    init(account: String = "journal-v1") { self.account = account }
    func key() throws -> Data {
        let authentication = LAContext(); authentication.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Zeus Journal", kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authentication]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw LearningStorageError.keyUnavailable }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let add = query.merging([kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new }
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key() }
        guard added == errSecSuccess else { throw LearningStorageError.keyUnavailable }
        return data
    }
}
enum LearningStorageError: Error, LocalizedError {
    case keyUnavailable, corrupt, invalidItem, invalidRule, missingRule
    var errorDescription: String? {
        switch self {
        case .keyUnavailable: "Zeus couldn't unlock its local journal."
        case .corrupt: "Zeus couldn't read an encrypted learning file. It has not been replaced."
        case .invalidItem: "This journal item isn't supported."
        case .invalidRule: "This rule has an invalid sentence, trigger, confidence or evidence."
        case .missingRule: "This rule no longer exists."
        }
    }
}
/// Authenticates both bytes and logical file identity; a day file cannot be moved to another day.
@MainActor enum LearningEncryption {
    static func read<T: Decodable>(_ type: T.Type, at url: URL, key: any JournalKeyProviding) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url)
        let secret = try key.key()
        return try decode(type, bytes: bytes, url: url, secret: secret)
    }
    /// The same authenticated format is used by synchronous reads and detached snapshot reads.
    nonisolated static func decode<T: Decodable>(_ type: T.Type, bytes: Data, url: URL, secret: Data) throws -> T {
        guard secret.count == 32 else { throw LearningStorageError.keyUnavailable }
        do {
            let box = try AES.GCM.SealedBox(combined: bytes)
            let clear = try AES.GCM.open(box, using: SymmetricKey(data: secret), authenticating: identity(url))
            return try JSONDecoder().decode(type, from: clear)
        } catch { throw LearningStorageError.corrupt }
    }
    static func write<T: Encodable>(_ value: T, to url: URL, key: any JournalKeyProviding) throws {
        let secret = try key.key()
        guard secret.count == 32 else { throw LearningStorageError.keyUnavailable }
        let clear = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(clear, using: SymmetricKey(data: secret), authenticating: identity(url))
        guard let bytes = box.combined else { throw LearningStorageError.corrupt }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // No plaintext staging file. Atomic encrypted replacement also preserves old contents on failure.
        try bytes.write(to: url, options: key.requiresProtectedFiles ? [.atomic, .completeFileProtection] : [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    nonisolated private static func identity(_ url: URL) -> Data { Data(("Zeus learning v1/" + url.lastPathComponent).utf8) }
}
