import Foundation

/// Снимок невыполненных задач для виджета. Базу и её миграции виджет не трогает: приложение пишет этот файл
/// в общий контейнер App Group. Порядки посчитаны заранее, поэтому правила сортировки живут только в `TaskOrdering`.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// На Mac группа `group.*` требует разрешения в профиле, а профиль Catalyst его не содержит:
    /// виджет не получает доступа к контейнеру. Группе с префиксом команды профиль не нужен.
    #if targetEnvironment(macCatalyst)
    static let appGroup = "235DAB995B.iliaIvanov.tasks"
    #else
    static let appGroup = "group.iliaIvanov.tasks"
    #endif
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

        /// Попадает ли задача в «Сегодня»: планируемый срок или дедлайн не позже этого дня.
        func isDue(on day: String) -> Bool {
            (plannedDay.map { $0 <= day } ?? false) || (deadlineDay.map { $0 <= day } ?? false)
        }
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

    /// Id пункта «Сегодня» в настройках виджета и ссылках.
    static let todayId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var lists: [List] = []
    /// Все невыполненные задачи со сроком. Отбор по дате делает виджет при отрисовке, чтобы в полночь список сменился сам.
    var today: List?

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
