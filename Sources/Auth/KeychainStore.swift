// OWNER: Auth module. SecItem wrappers — kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
import Foundation
import Security

enum KeychainStore {
    private static let service = "com.meetingalert.auth"

    static func saveString(_ string: String, account: String) throws {
        guard let data = string.data(using: .utf8) else { throw KeychainError.encodingFailed }
        try save(account: account, data: data)
    }

    static func loadString(account: String) throws -> String? {
        guard let data = try load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: Private

    private static func save(account: String, data: Data) throws {
        let del: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(del as CFDictionary)

        let add: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    account,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    private static func load(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.loadFailed(status) }
        return result as? Data
    }
}

public enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let s):   "Keychain save failed (OSStatus \(s))"
        case .loadFailed(let s):   "Keychain load failed (OSStatus \(s))"
        case .deleteFailed(let s): "Keychain delete failed (OSStatus \(s))"
        case .encodingFailed:       "Failed to encode string as UTF-8 for Keychain"
        }
    }
}
