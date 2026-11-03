import AppIntents
import WidgetKit

/// Список задач в настройках виджета.
struct TaskListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Список"
    static let defaultQuery = TaskListQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TaskListQuery: EntityQuery {
    private var all: [TaskListEntity] {
        (WidgetSnapshot.load()?.lists ?? []).map { TaskListEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [UUID]) async throws -> [TaskListEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TaskListEntity] { all }

    func defaultResult() async -> TaskListEntity? {
        WidgetSnapshot.load()?.inbox.map { TaskListEntity(id: $0.id, name: $0.name) }
    }
}

/// Сортировка виджета: как в самом списке или один из режимов `SortMode`.
enum WidgetSortOption: String, AppEnum {
    case listDefault, manual, priority, plannedDay, deadline, duration

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Сортировка"
    static let caseDisplayRepresentations: [WidgetSortOption: DisplayRepresentation] = [
        .listDefault: "Как в списке",
        .manual: "Вручную",
        .priority: "Приоритет",
        .plannedDay: "Планируемый срок",
        .deadline: "Дедлайн",
        .duration: "Длительность",
    ]

    /// `SortMode.rawValue`; `nil` — режим самого списка.
    var sortMode: String? { self == .listDefault ? nil : rawValue }
}

struct TaskListWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Список задач"
    static let description = IntentDescription("Задачи выбранного списка в нужном порядке.")

    @Parameter(title: "Список")
    var list: TaskListEntity?

    @Parameter(title: "Сортировка", default: .listDefault)
    var sort: WidgetSortOption
}
