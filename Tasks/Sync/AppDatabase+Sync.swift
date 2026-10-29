import Foundation
import GRDB

/// Изменения с сервера в моделях приложения (из proto их собирает `Network/`).
struct SyncChanges: Sendable {
    var checkpoint: UInt32 = 0
    var syncToken: Data?
    var lists: [TaskList] = []
    var deletedLists: [UUID] = []
    var sections: [ListSection] = []
    var deletedSections: [UUID] = []
    var priorities: [Priority] = []
    var deletedPriorities: [UUID] = []
    var durations: [DurationOption] = []
    var deletedDurations: [UUID] = []
    var tasks: [TaskItem] = []
    var deletedTasks: [UUID] = []
    var tags: [Tag] = []
    var deletedTags: [UUID] = []
    var addedTaskTags: [TaskTag] = []
    var removedTaskTags: [TaskTag] = []
    var blockers: [Blocker] = []
    var deletedBlockers: [UUID] = []
    var dailyCapacityMinutes: Int?

    var summary: String {
        let parts: [(String, Int)] = [
            ("списков", lists.count + deletedLists.count), ("разделов", sections.count + deletedSections.count),
            ("приоритетов", priorities.count + deletedPriorities.count), ("длительностей", durations.count + deletedDurations.count),
            ("задач", tasks.count + deletedTasks.count), ("тегов", tags.count + deletedTags.count),
            ("связей с тегами", addedTaskTags.count + removedTaskTags.count), ("блокеров", blockers.count + deletedBlockers.count),
        ]
        let text = parts.filter { $0.1 > 0 }.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
        return text.isEmpty ? "Изменений нет" : text
    }
}

extension AppDatabase {
    private static let checkpointKey = "sync.checkpoint"

    // MARK: - Очередь

    func nextQueued() throws -> QueuedMutation? {
        try writer.read { try QueuedMutation.order(Column("id")).fetchOne($0) }
    }

    func queue() throws -> [QueuedMutation] {
        try writer.read { try QueuedMutation.order(Column("id")).fetchAll($0) }
    }

    func observeQueueCount() -> AsyncValueObservation<Int> {
        observe { try QueuedMutation.fetchCount($0) }
    }

    func markInFlight(_ id: Int64, _ inFlight: Bool, error: String? = nil) throws {
        try writer.write { db in
            if error != nil {
                try db.execute(sql: "UPDATE syncQueue SET inFlight = ?, tryCount = tryCount + 1, lastError = ? WHERE id = ?",
                               arguments: [inFlight, error, id])
            } else {
                try db.execute(sql: "UPDATE syncQueue SET inFlight = ? WHERE id = ?", arguments: [inFlight, id])
            }
        }
    }

    /// После перезапуска приложения ничего не «в пути».
    func resetInFlight() throws {
        try writer.write { try $0.execute(sql: "UPDATE syncQueue SET inFlight = 0") }
    }

    func removeQueued(_ id: Int64) throws {
        _ = try writer.write { try QueuedMutation.deleteOne($0, key: id) }
    }

    /// Сервер отклонил создание — на сервере этой строки нет, локальная копия уходит.
    func dropRejectedCreate(_ mutation: Mutation) throws {
        try writer.write { db in
            let now = Date()
            func drop(_ table: String, _ id: UUID) throws {
                try db.execute(sql: "UPDATE \(table) SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            }
            switch mutation {
            case .createList(let v): try drop("taskList", v.id)
            case .createSection(let v): try drop("listSection", v.id)
            case .createPriority(let v): try drop("priority", v.id)
            case .createDuration(let v): try drop("durationOption", v.id)
            case .createTask(let v): try drop("taskItem", v.id)
            case .createTag(let v): try drop("tag", v.id)
            case .createBlocker(let v): try drop("blocker", v.id)
            default: break
            }
        }
    }

    // MARK: - Чекпоинт и сброс

    func checkpoint() throws -> UInt32 {
        try writer.read { db in try Self.setting(db, Self.checkpointKey).flatMap { UInt32($0) } ?? 0 }
    }

    /// Сохраняется после ConfirmSync: иначе сервер считает устройство несинхронизированным.
    func setCheckpoint(_ value: UInt32) throws {
        try writer.write { try Self.setSetting($0, Self.checkpointKey, String(value)) }
    }

    /// Полностью стирает данные пользователя, очередь и чекпоинт — перед входом и после выхода.
    func wipe() throws {
        try writer.write { db in
            for table in ["syncQueue", "blocker", "taskTag", "tag", "taskItem", "listSection", "taskList", "priority", "durationOption", "setting"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    // MARK: - Применение изменений с сервера

    /// Пишет изменения сервера. Строки с неотправленной правкой не трогаются: правка уйдёт на сервер,
    /// и следующий синк вернёт итог. `full` — ответ на синк с нуля: всё, чего в нём нет и что не ждёт
    /// отправки, на сервере уже не существует.
    func apply(_ changes: SyncChanges, full: Bool) throws {
        try writer.write { db in
            let pending = try Outbox.pendingKeys(db)
            func put<R: SyncedRecord>(_ records: [R]) throws {
                for var record in records where !pending.contains("\(R.entityPrefix):\(record.id)") {
                    record.deletedAt = nil
                    try record.save(db)
                }
            }
            func remove<R: SyncedRecord>(_ type: R.Type, _ ids: [UUID]) throws {
                for id in ids where !pending.contains("\(R.entityPrefix):\(id)") {
                    try db.execute(sql: "UPDATE \(R.databaseTableName) SET deletedAt = COALESCE(deletedAt, ?) WHERE id = ?", arguments: [Date(), id])
                }
            }
            if full {
                // Что сервер не прислал при синке с нуля — удалено или не создавалось
                func keep<R: SyncedRecord>(_ type: R.Type, _ ids: [UUID]) throws {
                    let alive = Set(ids)
                    for id in try UUID.fetchAll(db, sql: "SELECT id FROM \(R.databaseTableName) WHERE deletedAt IS NULL")
                    where !alive.contains(id) && !pending.contains("\(R.entityPrefix):\(id)") {
                        try db.execute(sql: "UPDATE \(R.databaseTableName) SET deletedAt = ? WHERE id = ?", arguments: [Date(), id])
                    }
                }
                try keep(TaskList.self, changes.lists.map(\.id))
                try keep(ListSection.self, changes.sections.map(\.id))
                try keep(Priority.self, changes.priorities.map(\.id))
                try keep(DurationOption.self, changes.durations.map(\.id))
                try keep(TaskItem.self, changes.tasks.map(\.id))
                try keep(Tag.self, changes.tags.map(\.id))
            }
            // Родители раньше детей — для внешних ключей
            try put(changes.lists)
            try put(changes.sections)
            try put(changes.priorities)
            try put(changes.durations)
            try put(changes.tags)
            try put(changes.tasks)
            for var link in changes.addedTaskTags where !pending.contains("taskTag:\(link.taskId):\(link.tagId)") {
                link.deletedAt = nil
                try link.save(db)
            }
            for link in changes.removedTaskTags where !pending.contains("taskTag:\(link.taskId):\(link.tagId)") {
                try db.execute(sql: "UPDATE taskTag SET deletedAt = COALESCE(deletedAt, ?) WHERE taskId = ? AND tagId = ?",
                               arguments: [Date(), link.taskId, link.tagId])
            }
            for var blocker in changes.blockers where !pending.contains("blocker:\(blocker.id)") {
                blocker.deletedAt = nil
                try blocker.save(db)
            }
            for id in changes.deletedBlockers where !pending.contains("blocker:\(id)") {
                try db.execute(sql: "UPDATE blocker SET deletedAt = COALESCE(deletedAt, ?) WHERE id = ?", arguments: [Date(), id])
            }
            try remove(TaskItem.self, changes.deletedTasks)
            try remove(Tag.self, changes.deletedTags)
            try remove(ListSection.self, changes.deletedSections)
            try remove(TaskList.self, changes.deletedLists)
            try remove(Priority.self, changes.deletedPriorities)
            try remove(DurationOption.self, changes.deletedDurations)
        }
    }
}
