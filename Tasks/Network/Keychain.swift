import Foundation
import Security

/// Токены и идентификатор устройства в Keychain.
enum Keychain {
    private static let service = "tasks.auth"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// Сессия пользователя: токены доступа и почта для показа.
enum TokenStore {
    static var accessToken: String? {
        get { Keychain.get("accessToken") }
        set { Keychain.set("accessToken", newValue) }
    }

    static var refreshToken: String? {
        get { Keychain.get("refreshToken") }
        set { Keychain.set("refreshToken", newValue) }
    }

    static var email: String? {
        get { Keychain.get("email") }
        set { Keychain.set("email", newValue) }
    }

    /// Постоянный идентификатор устройства для сервера (по нему сервер ведёт чекпоинт синка).
    static var deviceID: String {
        if let id = Keychain.get("deviceID") { return id }
        let id = UUID().uuidString
        Keychain.set("deviceID", id)
        return id
    }

    static func clear() {
        accessToken = nil
        refreshToken = nil
        email = nil
    }
}
