import Foundation
import Security

enum KeychainHelper {

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.island.mila.Mila",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.island.mila.Mila",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.island.mila.Mila",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// True only when the keychain positively reports the item absent.
    ///
    /// Not the same question as `load(key:) == nil`: `load` collapses every
    /// non-success status to nil, so a read *error* (a locked keychain, say)
    /// looks identical to "not there". A deletion verified through `load`
    /// could therefore claim success over a credential still sitting in the
    /// keychain. Only `errSecItemNotFound` is proof of absence.
    static func isAbsent(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.island.mila.Mila",
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound
    }
}
