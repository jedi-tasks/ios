import Foundation
import GRDB

/// Список задач. Ровно один список — системный Inbox.
struct TaskList: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var isInbox: Bool = false
    var colorHex: String = TaskList.palette[0]
    /// SF Symbol иконки списка.
    var icon: String = TaskList.icons[0]
    var sortOrder: Double = 0
    var sortMode: SortMode = .manual
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?
}

extension TaskList: FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskList"

    /// Цвета списков как в Напоминаниях.
    static let icons = [
        "list.bullet", "bookmark.fill", "mappin", "gift.fill", "graduationcap.fill", "doc.fill",
        "book.fill", "creditcard.fill", "dumbbell.fill", "figure.run", "bicycle", "fork.knife",
        "house.fill", "building.2.fill", "cart.fill", "airplane", "heart.fill", "pills.fill",
        "laptopcomputer", "hammer.fill", "server.rack", "network", "lock.shield.fill", "dollarsign.circle.fill",
        "chart.bar.fill", "lightbulb.fill", "star.fill", "flag.fill", "leaf.fill", "pawprint.fill",
    ]

    static let palette = ["#3E9BF0", "#E5484D", "#F5A524", "#FFD60A", "#30C26B", "#64D2FF", "#5E5CE6", "#BF5AF2", "#FF6482", "#A2845E", "#8E8E93"]
}

/// Необязательный раздел внутри списка.
struct ListSection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var listId: UUID
    var name: String
    var sortOrder: Double = 0
    var updatedAt: Date = Date()
    var deletedAt: Date?
}

extension ListSection: FetchableRecord, PersistableRecord {
    static let databaseTableName = "listSection"
}

/// Уровень приоритета из справочника. Меньший `sortOrder` — важнее.
struct Priority: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String
    /// Как приоритет выглядит в строке задачи, например `!!!`.
    var marks: String = "!"
    var sortOrder: Double = 0
    var updatedAt: Date = Date()
    var deletedAt: Date?
}

extension Priority: FetchableRecord, PersistableRecord {
    static let databaseTableName = "priority"
}

/// Значение из справочника длительностей. `minutes < 0` — «непрогнозируемо долго», в сумму не входит.
struct DurationOption: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var minutes: Int
    var updatedAt: Date = Date()
    var deletedAt: Date?

    var isUnpredictable: Bool { minutes < 0 }
}

extension DurationOption: FetchableRecord, PersistableRecord {
    static let databaseTableName = "durationOption"
}

struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var listId: UUID
    var sectionId: UUID?
    var title: String
    var notes: String = ""
    var priorityId: UUID?
    /// Ключи дней `yyyy-MM-dd`.
    var plannedDay: String?
    var deadlineDay: String?
    var durationMinutes: Int?
    var manualOrder: Double = 0
    var completedAt: Date?
    /// `calendarItemIdentifier` напоминания, из которого задача импортирована.
    var externalId: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?
}

extension TaskItem: FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskItem"
}

struct Tag: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var updatedAt: Date = Date()
    var deletedAt: Date?
}

extension Tag: FetchableRecord, PersistableRecord {
    static let databaseTableName = "tag"
}

struct TaskTag: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskTag"
    var taskId: UUID
    var tagId: UUID
    var updatedAt: Date = Date()
    var deletedAt: Date?
}

/// Блокер: ссылка на задачу либо текстовая причина. Жив, пока `resolvedAt == nil`.
struct Blocker: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var taskId: UUID
    var blockingTaskId: UUID?
    var reason: String?
    var sinceDay: String
    var resolvedAt: Date?
    var updatedAt: Date = Date()
    var deletedAt: Date?

    var isActive: Bool { resolvedAt == nil && deletedAt == nil }
}

extension Blocker: FetchableRecord, PersistableRecord {
    static let databaseTableName = "blocker"
}

enum SortMode: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case manual, priority, plannedDay, deadline, duration

    var title: String {
        switch self {
        case .manual: "Вручную"
        case .priority: "Приоритет"
        case .plannedDay: "Планируемый срок"
        case .deadline: "Дедлайн"
        case .duration: "Длительность"
        }
    }
}
