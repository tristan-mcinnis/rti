import Foundation
import Security

enum KeychainStore {
    private static let service = "com.tristan.rti"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return }
        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[RTI] KeychainStore set(\(account)) status=\(status)")
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum CredentialStore {
    private static let kimiAccount = "kimi"
    private static let sonioxAccount = "soniox"

    static var kimi: String? { KeychainStore.get(kimiAccount) }
    static var soniox: String? { KeychainStore.get(sonioxAccount) }

    static func setKimi(_ value: String) { KeychainStore.set(value, for: kimiAccount) }
    static func setSoniox(_ value: String) { KeychainStore.set(value, for: sonioxAccount) }

    /// One-time migration of any plaintext keys still living in Secrets.swift into the Keychain.
    /// After first run the user can clear `_legacy*` constants from Secrets.swift; values now live in Keychain.
    static func migrateLegacyIfNeeded() {
        let flag = "rti.credentials.migratedV1"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: flag) { return }
        if kimi == nil, !Secrets._legacyKimiKey.isEmpty, !Secrets._legacyKimiKey.hasPrefix("<") {
            setKimi(Secrets._legacyKimiKey)
        }
        if soniox == nil, !Secrets._legacySonioxKey.isEmpty, !Secrets._legacySonioxKey.hasPrefix("<") {
            setSoniox(Secrets._legacySonioxKey)
        }
        defaults.set(true, forKey: flag)
    }
}
