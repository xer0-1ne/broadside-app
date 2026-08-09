import Foundation
import Security

/// The Keychain, wrapped down to the three operations this app needs.
///
/// The API token is the whole of a Broadside account's write access: anything
/// holding it can publish, edit, and delete. That rules out UserDefaults, which
/// is a plist in the app container and is included in unencrypted backups.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the accessibility this
/// wants. AfterFirstUnlock rather than WhenUnlocked because a background upload
/// finishing while the phone is in a pocket still needs the token.
/// ThisDeviceOnly because a token restored onto a different phone from a backup
/// is a credential that has quietly spread.
enum Keychain {
    enum Failure: Error {
        case unexpectedStatus(OSStatus)
    }

    static func set(_ value: String, for key: String, service: String) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Update first, then add. SecItemAdd on an existing item fails with
        // errSecDuplicateItem rather than replacing, so the order matters.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }

        if updated == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }

            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.unexpectedStatus(added) }
            return
        }

        throw Failure.unexpectedStatus(updated)
    }

    static func get(_ key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    static func remove(_ key: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // A missing item is the desired end state, so errSecItemNotFound is
        // success as far as the caller is concerned.
        SecItemDelete(query as CFDictionary)
    }
}
