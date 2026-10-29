import Foundation
import OSLog
import SwiftProtobuf

private let logger = Logger(subsystem: "tasks", category: "API")

/// Журнал запросов к серверу: пишется в OSLog и держит последние записи в памяти для экрана разработчика.
/// Токены и пароли в тексте запросов и ответов заменяются на «•••».
@MainActor
@Observable
final class APILog {
    static let shared = APILog()

    /// Одна пара запрос-ответ.
    struct Entry: Identifiable, Sendable {
        let id = UUID()
        var date: Date
        var method: String
        var duration: Duration
        var request: String
        var response: String?
        var error: String?

        var isFailure: Bool { error != nil }
    }

    private static let limit = 300
    private(set) var entries: [Entry] = []

    func append(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func clear() { entries = [] }

    // MARK: - Запись из сетевого слоя

    /// Фиксирует вызов: в OSLog — строка со статусом и временем, в память — тексты запроса и ответа.
    nonisolated static func record(_ method: String, request: some Message, started: ContinuousClock.Instant,
                                   response: (some Message)?, error: String?) {
        let entry = Entry(
            date: Date(), method: method, duration: ContinuousClock.now - started,
            request: describe(request), response: response.map(describe), error: error
        )
        let ms = entry.duration.components.attoseconds / 1_000_000_000_000_000 + entry.duration.components.seconds * 1000
        if let error {
            logger.warning("✗ \(method, privacy: .public) \(ms)ms: \(error, privacy: .public)\n\(entry.request, privacy: .public)")
        } else {
            logger.info("✓ \(method, privacy: .public) \(ms)ms\n\(entry.request, privacy: .public)")
        }
        Task { @MainActor in shared.append(entry) }
    }

    nonisolated private static let secretFields = try! Regex(
        #"(?m)^(\s*)(access_token|refresh_token|token|password|old_password|new_password): .*$"#
    )
    nonisolated private static let maxLength = 8000

    /// Текст сообщения без секретов, обрезанный до разумной длины.
    nonisolated static func describe(_ message: some Message) -> String {
        var text = message.textFormatString().replacing(secretFields) { "\($0.output[1].substring ?? "")\($0.output[2].substring ?? ""): •••" }
        if text.count > maxLength { text = String(text.prefix(maxLength)) + "\n… обрезано" }
        return text.isEmpty ? "(пусто)" : text
    }
}
