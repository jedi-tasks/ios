import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "tasks", category: "Keychain")

/// Токены и идентификатор устройства в Keychain. Значения дублируются в памяти, а если Keychain
/// недоступен (Mac-сборка без доступа к связке ключей), — в UserDefaults: иначе вход проходит,
/// а токен тут же теряется и все запросы падают с «Не выполнен вход».
enum Keychain {
    private static let service = "tasks.auth"
    private static let fallbackPrefix = "keychainFallback."
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let value = cache[key] { return value }
        let value = read(key) ?? UserDefaults.standard.string(forKey: fallbackPrefix + key)
        cache[key] = value
        return value
    }

    static func set(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = value
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
        if !write(key, value), let value {
            UserDefaults.standard.set(value, forKey: fallbackPrefix + key)
        }
    }

    private static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Чтение \(key, privacy: .public) из Keychain: OSStatus \(status)")
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Возвращает false, если значение не удалось сохранить в Keychain.
    private static func write(_ key: String, _ value: String?) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Запись \(key, privacy: .public) в Keychain: OSStatus \(status), значение сохранено в UserDefaults")
        }
        return status == errSecSuccess
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
