import Foundation
import LocalAuthentication
import Security

/// Site keys in the Keychain: this device only, never backed up or synced, and readable only
/// with user presence (Face ID or passcode). Reads reuse the LAContext from the app unlock,
/// so there's one Face ID prompt per session rather than one per request.
enum TokenStore {
    private static let service = "com.merimerimeri.Quill.site-key"

    enum StoreError: LocalizedError {
        case noPasscode
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noPasscode:
                "Set a device passcode first. Quill only stores site keys on a passcode-protected device."
            case .status(let status):
                (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            }
        }
    }

    static func save(_ key: String, for siteID: UUID, context: LAContext?) throws {
        delete(siteID)
        var query = baseQuery(siteID)
        query[kSecValueData as String] = Data(key.utf8)
        query.merge(protection(), uniquingKeysWith: { $1 })
        if let context { query[kSecUseAuthenticationContext as String] = context }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecAuthFailed || status == errSecNotAvailable { throw StoreError.noPasscode }
        guard status == errSecSuccess else { throw StoreError.status(status) }
    }

    static func read(_ siteID: UUID, context: LAContext?) throws -> String? {
        var query = baseQuery(siteID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError.status(status) }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ siteID: UUID) {
        SecItemDelete(baseQuery(siteID) as CFDictionary)
    }

    private static func baseQuery(_ siteID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: siteID.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func protection() -> [String: Any] {
        #if targetEnvironment(simulator)
        // The simulator has no passcode, so a presence-bound item can't be created there.
        // The app-level Face ID lock still applies.
        return [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        #else
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error
        ) else {
            return [kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
        }
        return [kSecAttrAccessControl as String: access]
        #endif
    }
}
