import Foundation

/// Снимок невыполненных задач для виджета. Базу и её миграции виджет не трогает: приложение пишет этот файл
/// в общий контейнер App Group. Порядки посчитаны заранее, поэтому правила сортировки живут только в `TaskOrdering`.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let appGroup = "group.iliaIvanov.tasks"
    /// `kind` виджета — по нему приложение просит обновить таймлайны.
    static let widgetKind = "TaskListWidget"

    struct Task: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var title: String
        var priorityMarks: String?
        var priorityColorHex: String?
        var plannedDay: String?
        var deadlineDay: String?
        var isBlocked: Bool
    }

    struct List: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var colorHex: String
        var icon: String
        var isInbox: Bool
        /// Режим сортировки самого списка: `SortMode.rawValue`.
        var sortMode: String
        var tasks: [Task]
        /// Порядок id задач для каждого режима: `SortMode.rawValue` → id.
        var orders: [String: [UUID]]

        /// Задачи в порядке режима; `nil` — режим самого списка.
        func sortedTasks(by mode: String?) -> [Task] {
            let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            return (orders[mode ?? sortMode] ?? []).compactMap { byId[$0] }
        }
    }

    var lists: [List] = []

    var inbox: List? { lists.first(where: \.isInbox) }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Ссылки из виджета в приложение.
enum WidgetLink: Equatable {
    case list(UUID)
    case task(UUID)

    private static let scheme = "tasks"

    var url: URL {
        switch self {
        case .list(let id): URL(string: "\(Self.scheme)://list/\(id.uuidString)")!
        case .task(let id): URL(string: "\(Self.scheme)://task/\(id.uuidString)")!
        }
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        switch url.host {
        case "list": self = .list(id)
        case "task": self = .task(id)
        default: return nil
        }
    }
}
