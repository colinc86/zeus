import Foundation
import Security
import LocalAuthentication

@MainActor
protocol OpenCodePasswordStoring {
    func read() throws -> String?
    func save(_ password: String?) throws
}

/// A single OpenCode server credential; never serialized into preferences or card history.
@MainActor
struct OpenCodePasswordStore: OpenCodePasswordStoring {
    private let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: "com.colinc86.Zeus",
                                         kSecAttrAccount as String: "opencode-server-password"]
    func read() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PasswordError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw PasswordError(status: errSecDecode) }
        return value
    }
    func save(_ password: String?) throws {
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PasswordError(status: status) }
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw PasswordError(status: added) }
        } else if status != errSecSuccess { throw PasswordError(status: status) }
    }
    private struct PasswordError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "Could not access the saved password.")" }
    }
}
