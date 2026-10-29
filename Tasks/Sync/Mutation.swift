import Foundation
import GRDB

/// Правка, которую надо отправить на сервер. Пишется в очередь (`syncQueue`) в той же транзакции,
/// что и локальное изменение, и уходит на сервер по порядку записи. Порядок важен: сервер не делает
/// скрытых каскадов, поэтому доменный слой (`AppDatabase`) ставит дочерние правки раньше родительских.
/// Модели внутри — снимок строки на момент правки (без proto: конвертация — в `Network/`).
enum Mutation: Codable, Sendable, Equatable {
    case createList(TaskList), updateList(TaskList), deleteList(UUID, at: Date)
    case createSection(ListSection), updateSection(ListSection), deleteSection(UUID, at: Date)
    case createPriority(Priority), updatePriority(Priority), deletePriority(UUID, at: Date)
    case createDuration(DurationOption), updateDuration(DurationOption), deleteDuration(UUID, at: Date)
    case createTask(TaskItem), updateTask(TaskItem), setCompleted(UUID, Bool, at: Date), deleteTask(UUID, at: Date)
    case createTag(Tag), updateTag(Tag), deleteTag(UUID, at: Date)
    case addTag(task: UUID, tag: UUID, at: Date), removeTag(task: UUID, tag: UUID, at: Date)
    case createBlocker(Blocker), resolveBlocker(UUID, at: Date), deleteBlocker(UUID, at: Date)
    case updateSettings(dailyCapacityMinutes: Int, at: Date)

    /// Сущность, которую меняет правка: по ней синк не затирает строку с неотправленной правкой.
    var entityKey: String {
        switch self {
        case .createList(let v), .updateList(let v): "list:\(v.id)"
        case .deleteList(let id, _): "list:\(id)"
        case .createSection(let v), .updateSection(let v): "section:\(v.id)"
        case .deleteSection(let id, _): "section:\(id)"
        case .createPriority(let v), .updatePriority(let v): "priority:\(v.id)"
        case .deletePriority(let id, _): "priority:\(id)"
        case .createDuration(let v), .updateDuration(let v): "duration:\(v.id)"
        case .deleteDuration(let id, _): "duration:\(id)"
        case .createTask(let v), .updateTask(let v): "task:\(v.id)"
        case .setCompleted(let id, _, _), .deleteTask(let id, _): "task:\(id)"
        case .createTag(let v), .updateTag(let v): "tag:\(v.id)"
        case .deleteTag(let id, _): "tag:\(id)"
        case .addTag(let task, let tag, _), .removeTag(let task, let tag, _): "taskTag:\(task):\(tag)"
        case .createBlocker(let v): "blocker:\(v.id)"
        case .resolveBlocker(let id, _), .deleteBlocker(let id, _): "blocker:\(id)"
        case .updateSettings: "settings"
        }
    }

    /// Новый снимок той же сущности можно влить в ещё не отправленную create/update-правку.
    func merged(into previous: Mutation) -> Mutation? {
        switch (previous, self) {
        case (.createList, .updateList(let v)): .createList(v)
        case (.updateList, .updateList(let v)): .updateList(v)
        case (.createSection, .updateSection(let v)): .createSection(v)
        case (.updateSection, .updateSection(let v)): .updateSection(v)
        case (.createPriority, .updatePriority(let v)): .createPriority(v)
        case (.updatePriority, .updatePriority(let v)): .updatePriority(v)
        case (.createDuration, .updateDuration(let v)): .createDuration(v)
        case (.updateDuration, .updateDuration(let v)): .updateDuration(v)
        case (.createTask, .updateTask(let v)): .createTask(v)
        case (.updateTask, .updateTask(let v)): .updateTask(v)
        case (.updateSettings, .updateSettings): self
        default: nil
        }
    }

    var isCreate: Bool {
        switch self {
        case .createList, .createSection, .createPriority, .createDuration, .createTask, .createTag, .createBlocker: true
        default: false
        }
    }

    /// Для инструментов разработчика.
    var title: String {
        let name = "\(self)".prefix(while: { $0 != "(" })
        return "\(name) \(entityKey)"
    }
}

/// Строка очереди синка.
struct QueuedMutation: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "syncQueue"
    var id: Int64?
    var entityKey: String
    var payload: Data
    var tryCount: Int = 0
    var lastError: String?
    var inFlight: Bool = false
    var createdAt: Date = Date()

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var mutation: Mutation? { try? JSONDecoder().decode(Mutation.self, from: payload) }
}

enum Outbox {
    /// Ставит правку в очередь. Подряд идущие правки одной сущности (набор текста) сливаются в одну.
    static func enqueue(_ db: Database, _ mutation: Mutation) throws {
        if var last = try QueuedMutation.order(Column("id").desc).fetchOne(db),
           !last.inFlight, last.entityKey == mutation.entityKey,
           let previous = last.mutation, let merged = mutation.merged(into: previous) {
            last.payload = try JSONEncoder().encode(merged)
            try last.update(db)
            return
        }
        var row = QueuedMutation(entityKey: mutation.entityKey, payload: try JSONEncoder().encode(mutation))
        try row.insert(db)
    }

    static func pendingKeys(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT entityKey FROM syncQueue"))
    }
}

/// Время правок строго возрастает: сервер применяет правку, только если она новее сохранённой,
/// и две правки одной сущности в одну миллисекунду (create и сразу complete) не должны совпасть.
enum SyncClock {
    nonisolated(unsafe) private static var last = Date.distantPast
    private static let lock = NSLock()

    static func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        var date = Date()
        if date <= last.addingTimeInterval(0.001) { date = last.addingTimeInterval(0.001) }
        last = date
        return date
    }
}
