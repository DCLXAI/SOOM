import Foundation
import Security

enum KeychainStore {
    private static let service = "com.soom.macos.openai"
    private static let legacyService = "com.showtellai.macos.openai"
    private static let shareService = "com.soom.macos.share-upload"
    private static let account = "default"

    static func saveAPIKey(_ value: String) throws {
        try save(value, service: service)
    }

    static func saveShareToken(_ value: String) throws {
        try save(value, service: shareService)
    }

    static func deleteAPIKey() throws {
        try delete(service: service)
        // A migrated key must not silently return on the next launch.
        try delete(service: legacyService)
    }

    static func loadShareToken() -> String? {
        load(service: shareService)
    }

    private static func save(_ value: String, service: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func loadAPIKey() -> String? {
        if let current = load(service: service) { return current }
        guard let legacy = load(service: legacyService) else { return nil }
        try? saveAPIKey(legacy)
        return legacy
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 오류 \(status)"
    }
}
