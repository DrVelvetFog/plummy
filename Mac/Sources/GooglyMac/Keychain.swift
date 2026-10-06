import Foundation
import Security

/// API keys and the pairing secret live in the macOS Keychain — encrypted at rest and gated by the
/// system — not in a file. The first time it runs, it migrates any keys from the old plaintext file
/// (`~/Library/Application Support/Googly/keys.json`) into the Keychain and then removes that file,
/// but only once every key has been read back from the Keychain, so a key is never lost.
enum Keychain {
    enum Key: String, CaseIterable {
        case anthropic, elevenlabs, openai, pairing
    }

    /// The Keychain "service" these items are filed under (visible in Keychain Access).
    private static let service = "Velvet"

    static func get(_ key: Key) -> String? {
        migrateIfNeeded()
        return read(key.rawValue)
    }

    static func set(_ key: Key, _ value: String?) {
        migrateIfNeeded()
        write(key.rawValue, value?.isEmpty == false ? value : nil)
    }

    // MARK: Keychain primitives

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    private static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        if SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
    }

    // MARK: One-time migration from the old plaintext file

    private static var migrated = false

    private static func migrateIfNeeded() {
        if migrated { return }
        migrated = true
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly", isDirectory: true)
            .appendingPathComponent("keys.json")
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        var allMoved = true
        for (account, value) in stored where !value.isEmpty {
            if read(account) != value { write(account, value) }
            if read(account) != value { allMoved = false }  // keychain write didn't stick — keep the file
        }
        if allMoved { try? FileManager.default.removeItem(at: file) }
    }
}
