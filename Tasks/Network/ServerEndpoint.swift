import Foundation

/// Адрес gRPC-сервера. По умолчанию — по конфигурации сборки; в инструментах разработчика можно
/// выбрать другой (хранится в UserDefaults).
struct ServerEndpoint: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    var tls: Bool

    var title: String { "\(host):\(port)\(tls ? "" : " (без TLS)")" }

    static let dev = ServerEndpoint(host: "tasks.dev.bonavii.com", port: 443, tls: true)
    static let prod = ServerEndpoint(host: "tasks.bonavii.com", port: 443, tls: true)
    /// Локальный сервер для разработки: gRPC без TLS.
    static let local = ServerEndpoint(host: "localhost", port: 18081, tls: false)

    static let presets: [(name: String, endpoint: ServerEndpoint)] = [("Dev", .dev), ("Prod", .prod), ("Локальный", .local)]

    #if DEBUG
    static let buildDefault = ServerEndpoint.dev
    #else
    static let buildDefault = ServerEndpoint.prod
    #endif

    private static let key = "serverEndpointOverride"

    /// Текущий адрес: переопределение из инструментов разработчика или значение сборки.
    static var current: ServerEndpoint {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let endpoint = try? JSONDecoder().decode(ServerEndpoint.self, from: data) else { return buildDefault }
            return endpoint
        }
        set {
            if newValue == buildDefault {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            }
        }
    }
}
