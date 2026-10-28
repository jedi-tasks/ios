import Foundation
import GRDB
import OSLog

private let logger = Logger(subsystem: "tasks", category: "Database")

struct AppDatabase: Sendable {
    private let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static func makeShared() throws -> AppDatabase {
        let fileManager = FileManager()
        let directory = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("database", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("db.sqlite")
        logger.info("Database stored at \(url.path)")
        return try AppDatabase(DatabasePool(path: url.path))
    }

    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: - Чтение

    func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T> {
        ValueObservation.tracking(fetch).values(in: writer)
    }

    func board() throws -> Board {
        try writer.read(Self.fetchBoard)
    }

    static func fetchBoard(_ db: Database) throws -> Board {
        let alive = Column("deletedAt") == nil
        let lists = try TaskList.filter(alive).order(Column("isInbox").desc, Column("sortOrder")).fetchAll(db)
        let sections = try ListSection.filter(alive).order(Column("sortOrder")).fetchAll(db)
        let priorities = try Priority.filter(alive).order(Column("sortOrder")).fetchAll(db)
        let tags = try Tag.filter(alive).order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        let taskTags = try TaskTag.filter(alive).fetchAll(db)
        let blockers = try Blocker.filter(alive).order(Column("sinceDay")).fetchAll(db)
        let tasks = try TaskItem.filter(alive).order(Column("manualOrder")).fetchAll(db)

        let priorityById = Dictionary(uniqueKeysWithValues: priorities.map { ($0.id, $0) })
        let colorByList = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.colorHex) })
        let tagById = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let tagsByTask = Dictionary(grouping: taskTags, by: \.taskId)
        let blockersByTask = Dictionary(grouping: blockers, by: \.taskId)
        let rows = tasks.map { task in
            TaskRow(
                task: task,
                priority: task.priorityId.flatMap { priorityById[$0] },
                listColorHex: colorByList[task.listId] ?? TaskList.palette[0],
                tags: (tagsByTask[task.id] ?? []).compactMap { tagById[$0.tagId] }.sorted { $0.name < $1.name },
                blockers: blockersByTask[task.id] ?? []
            )
        }
        return Board(lists: lists, sections: sections, priorities: priorities, tags: tags, rows: rows)
    }

    // MARK: - Списки и разделы

    func saveList(_ list: TaskList) throws {
        try writer.write { db in
            var list = list
            if try TaskList.fetchOne(db, key: list.id) == nil {
                list.sortOrder = try Self.nextOrder(db, table: "taskList", column: "sortOrder")
            }
            list.updatedAt = Date()
            try list.save(db)
        }
    }

    /// Удаляет список вместе с задачами и разделами. Inbox не удаляется.
    func deleteList(_ id: UUID) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE taskList SET deletedAt = ?, updatedAt = ? WHERE id = ? AND isInbox = 0", arguments: [now, now, id])
            guard db.changesCount > 0 else { return }
            try db.execute(sql: "UPDATE listSection SET deletedAt = ?, updatedAt = ? WHERE listId = ? AND deletedAt IS NULL", arguments: [now, now, id])
            let taskIds = try UUID.fetchAll(db, sql: "SELECT id FROM taskItem WHERE listId = ? AND deletedAt IS NULL", arguments: [id])
            for taskId in taskIds { try Self.deleteTask(db, taskId, now: now) }
        }
    }

    /// Ручная расстановка списка после перетаскивания: `order` — все открытые задачи списка в новом порядке,
    /// `moved` переезжают в `section` этого списка. Список переключается на ручную сортировку.
    func arrange(list listId: UUID, order: [UUID], moved: [UUID], section: UUID?) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE taskList SET sortMode = ?, updatedAt = ? WHERE id = ?", arguments: [SortMode.manual, now, listId])
            for id in moved {
                try db.execute(sql: "UPDATE taskItem SET listId = ?, sectionId = ?, updatedAt = ? WHERE id = ?",
                               arguments: [listId, section, now, id])
            }
            for (index, id) in order.enumerated() {
                try db.execute(sql: "UPDATE taskItem SET manualOrder = ?, updatedAt = ? WHERE id = ?", arguments: [Double(index), now, id])
            }
        }
    }

    func setSortMode(_ mode: SortMode, list id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE taskList SET sortMode = ?, updatedAt = ? WHERE id = ?", arguments: [mode, Date(), id])
        }
    }

    func saveSection(_ section: ListSection) throws {
        try writer.write { db in
            var section = section
            if try ListSection.fetchOne(db, key: section.id) == nil {
                section.sortOrder = try Self.nextOrder(db, table: "listSection", column: "sortOrder")
            }
            section.updatedAt = Date()
            try section.save(db)
        }
    }

    /// Задачи раздела остаются в списке без раздела.
    func deleteSection(_ id: UUID) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE listSection SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try db.execute(sql: "UPDATE taskItem SET sectionId = NULL, updatedAt = ? WHERE sectionId = ?", arguments: [now, id])
        }
    }

    /// Записывает порядок по индексу в массиве. `table` — taskList, listSection, priority или taskItem.
    func reorder(table: String, ids: [UUID]) throws {
        let column = table == "taskItem" ? "manualOrder" : "sortOrder"
        try writer.write { db in
            let now = Date()
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE \(table) SET \(column) = ?, updatedAt = ? WHERE id = ?", arguments: [Double(index), now, id])
            }
        }
    }

    // MARK: - Приоритеты

    func savePriority(_ priority: Priority) throws {
        try writer.write { db in
            var priority = priority
            if try Priority.fetchOne(db, key: priority.id) == nil {
                priority.sortOrder = try Self.nextOrder(db, table: "priority", column: "sortOrder")
            }
            priority.updatedAt = Date()
            try priority.save(db)
        }
    }

    /// Задачи с этим приоритетом становятся «не разобрано».
    func deletePriority(_ id: UUID) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE priority SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
            try db.execute(sql: "UPDATE taskItem SET priorityId = NULL, updatedAt = ? WHERE priorityId = ?", arguments: [now, id])
        }
    }

    // MARK: - Задачи

    /// Сохраняет задачу и заменяет набор её тегов (по названиям; новые теги создаются).
    @discardableResult
    func saveTask(_ task: TaskItem, tags: [String]? = nil) throws -> TaskItem {
        try writer.write { db in
            var task = task
            let now = Date()
            let existing = try TaskItem.fetchOne(db, key: task.id)
            if existing == nil || existing?.listId != task.listId {
                task.manualOrder = try Self.nextOrder(db, table: "taskItem", column: "manualOrder")
            }
            if let sectionId = task.sectionId,
               try ListSection.fetchOne(db, key: sectionId)?.listId != task.listId {
                task.sectionId = nil
            }
            task.updatedAt = now
            try task.save(db)
            if let tags { try Self.replaceTags(db, task: task.id, names: tags, now: now) }
            if existing?.completedAt == nil, task.completedAt != nil {
                try Self.resolveBlockers(db, by: task.id, now: now)
            }
            return task
        }
    }

    /// Новая задача; без списка — в Inbox.
    @discardableResult
    func addTask(title: String, listId: UUID?, sectionId: UUID? = nil, plannedDay: String? = nil) throws -> TaskItem {
        let target = try listId ?? writer.read { db in
            try TaskList.filter(Column("isInbox") == true && Column("deletedAt") == nil).fetchOne(db)?.id
        }
        guard let target else { throw DatabaseError(message: "Нет Inbox") }
        return try saveTask(TaskItem(listId: target, sectionId: sectionId, title: title, plannedDay: plannedDay))
    }

    /// Выполнение снимает блокеры, ссылающиеся на задачу.
    func setCompleted(_ id: UUID, _ completed: Bool) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE taskItem SET completedAt = ?, updatedAt = ? WHERE id = ?",
                           arguments: [completed ? now : nil, now, id])
            if completed { try Self.resolveBlockers(db, by: id, now: now) }
        }
    }

    func deleteTask(_ id: UUID) throws {
        try writer.write { db in try Self.deleteTask(db, id, now: Date()) }
    }

    /// Мягкое удаление задачи; блокеры, ссылающиеся на неё, удаляются тоже — иначе зависнут навсегда.
    private static func deleteTask(_ db: Database, _ id: UUID, now: Date) throws {
        try db.execute(sql: "UPDATE taskItem SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
        try db.execute(sql: "UPDATE blocker SET deletedAt = ?, updatedAt = ? WHERE (taskId = ? OR blockingTaskId = ?) AND deletedAt IS NULL",
                       arguments: [now, now, id, id])
        try db.execute(sql: "UPDATE taskTag SET deletedAt = ?, updatedAt = ? WHERE taskId = ? AND deletedAt IS NULL", arguments: [now, now, id])
        try pruneTags(db, now: now)
    }

    private static func replaceTags(_ db: Database, task: UUID, names: [String], now: Date) throws {
        var tagIds: [UUID] = []
        for name in names.map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            let lower = name.lowercased()
            if let tag = try Tag.filter(Column("deletedAt") == nil).fetchAll(db).first(where: { $0.name.lowercased() == lower }) {
                tagIds.append(tag.id)
            } else {
                let tag = Tag(name: name, updatedAt: now)
                try tag.insert(db)
                tagIds.append(tag.id)
            }
        }
        try db.execute(sql: "UPDATE taskTag SET deletedAt = ?, updatedAt = ? WHERE taskId = ? AND deletedAt IS NULL", arguments: [now, now, task])
        for tagId in Set(tagIds) {
            try TaskTag(taskId: task, tagId: tagId, updatedAt: now).save(db)
        }
        try pruneTags(db, now: now)
    }

    /// Теги, не висящие ни на одной живой задаче, удаляются — теги существуют только через задачи.
    static func pruneTags(_ db: Database, now: Date) throws {
        try db.execute(sql: """
            UPDATE tag SET deletedAt = ?, updatedAt = ?
            WHERE deletedAt IS NULL AND id NOT IN (
                SELECT tt.tagId FROM taskTag tt JOIN taskItem t ON t.id = tt.taskId
                WHERE tt.deletedAt IS NULL AND t.deletedAt IS NULL)
            """, arguments: [now, now])
    }

    /// Что можно назначить задаче броском на объект (список, приоритет, тег…) или из меню.
    enum Assignment: Sendable {
        case list(UUID)
        case priority(UUID?)
        case duration(Int?)
        case tag(UUID)
        case plannedDay(String?)
    }

    func assign(_ assignment: Assignment, to taskId: UUID) throws {
        if case .tag(let tagId) = assignment {
            try writer.write { db in
                // Тег добавляется к имеющимся, а не заменяет их
                try TaskTag(taskId: taskId, tagId: tagId, updatedAt: Date()).save(db)
                try db.execute(sql: "UPDATE taskItem SET updatedAt = ? WHERE id = ?", arguments: [Date(), taskId])
            }
            return
        }
        guard var task = try writer.read({ try TaskItem.fetchOne($0, key: taskId) }) else { return }
        switch assignment {
        case .list(let id):
            guard task.listId != id else { return }
            task.listId = id
            task.sectionId = nil
        case .priority(let id): task.priorityId = id
        case .duration(let minutes): task.durationMinutes = minutes
        case .plannedDay(let day): task.plannedDay = day
        case .tag: break
        }
        try saveTask(task)
    }

    // MARK: - Блокеры

    enum BlockerError: LocalizedError {
        case cycle
        var errorDescription: String? { "Получится цикл: эта задача уже блокирует выбранную." }
    }

    func addBlocker(task: UUID, blockingTask: UUID? = nil, reason: String? = nil, sinceDay: String = DayKey.today) throws {
        try writer.write { db in
            if let blockingTask {
                let edges = try Blocker
                    .filter(Column("deletedAt") == nil && Column("resolvedAt") == nil && Column("blockingTaskId") != nil)
                    .fetchAll(db)
                    .map { (task: $0.taskId, blocking: $0.blockingTaskId!) }
                if BlockerGraph.wouldCycle(task: task, blocking: blockingTask, edges: edges) { throw BlockerError.cycle }
                // Блокировать уже выполненной задачей бессмысленно — блокер сразу снят
                let done = try TaskItem.fetchOne(db, key: blockingTask)?.completedAt != nil
                try Blocker(taskId: task, blockingTaskId: blockingTask, sinceDay: sinceDay, resolvedAt: done ? Date() : nil).insert(db)
            } else {
                try Blocker(taskId: task, reason: reason, sinceDay: sinceDay).insert(db)
            }
        }
    }

    func resolveBlocker(_ id: UUID) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE blocker SET resolvedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
        }
    }

    func deleteBlocker(_ id: UUID) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: "UPDATE blocker SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, id])
        }
    }

    private static func resolveBlockers(_ db: Database, by taskId: UUID, now: Date) throws {
        try db.execute(sql: "UPDATE blocker SET resolvedAt = ?, updatedAt = ? WHERE blockingTaskId = ? AND resolvedAt IS NULL",
                       arguments: [now, now, taskId])
    }

    // MARK: - Импорт из Reminders

    /// Добавляет напоминания, которых ещё нет (по `externalId`, включая удалённые — их не возвращаем).
    /// Списки и разделы находятся по имени или создаются; список Reminders «Inbox» — системный Inbox.
    func importReminders(_ reminders: [ImportedReminder]) throws -> ImportResult {
        try writer.write { db in
            var result = ImportResult()
            let now = Date()
            let known = Set(try String.fetchAll(db, sql: "SELECT externalId FROM taskItem WHERE externalId IS NOT NULL"))
            let priorities = try Priority.filter(Column("deletedAt") == nil).order(Column("sortOrder")).fetchAll(db)
            var order = try Self.nextOrder(db, table: "taskItem", column: "manualOrder")

            for reminder in reminders {
                guard !known.contains(reminder.externalId) else { result.skipped += 1; continue }
                let list = try Self.importList(db, named: reminder.listName, colorHex: reminder.listColorHex)
                let note = ReminderNote.parse(reminder.notes)
                let section = try note.section.map { try Self.importSection(db, named: $0, in: list.id) }
                let task = TaskItem(
                    listId: list.id,
                    sectionId: section?.id,
                    title: reminder.title,
                    notes: note.body,
                    priorityId: Self.priority(for: reminder.priority, in: priorities)?.id,
                    plannedDay: reminder.dueDay,
                    durationMinutes: note.durationMinutes,
                    manualOrder: order,
                    completedAt: reminder.completedAt,
                    externalId: reminder.externalId,
                    createdAt: now,
                    updatedAt: now
                )
                order += 1
                try task.insert(db)
                if let reason = note.blockerReason {
                    try Blocker(taskId: task.id, reason: reason, sinceDay: note.blockerSinceDay ?? DayKey.today,
                                resolvedAt: reminder.completedAt).insert(db)
                }
                result.added += 1
            }
            return result
        }
    }

    /// Высокий / средний / низкий EventKit → первый / второй / третий уровень справочника.
    static func priority(for ekPriority: Int, in priorities: [Priority]) -> Priority? {
        let index: Int
        switch ekPriority {
        case 1...4: index = 0
        case 5: index = 1
        case 6...9: index = 2
        default: return nil
        }
        return priorities.indices.contains(index) ? priorities[index] : priorities.last
    }

    private static func importList(_ db: Database, named name: String, colorHex: String?) throws -> TaskList {
        let lists = try TaskList.filter(Column("deletedAt") == nil).fetchAll(db)
        if name.caseInsensitiveCompare("Inbox") == .orderedSame, let inbox = lists.first(where: \.isInbox) { return inbox }
        if let list = lists.first(where: { !$0.isInbox && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return list }
        let list = TaskList(name: name, colorHex: colorHex ?? TaskList.palette[0], sortOrder: try nextOrder(db, table: "taskList", column: "sortOrder"))
        try list.insert(db)
        return list
    }

    private static func importSection(_ db: Database, named name: String, in listId: UUID) throws -> ListSection {
        let sections = try ListSection.filter(Column("deletedAt") == nil && Column("listId") == listId).fetchAll(db)
        if let section = sections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return section }
        let section = ListSection(listId: listId, name: name, sortOrder: try nextOrder(db, table: "listSection", column: "sortOrder"))
        try section.insert(db)
        return section
    }

    // MARK: - Настройки

    static func setting(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ? AND deletedAt IS NULL", arguments: [key])
    }

    func setSetting(_ key: String, _ value: String?) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO setting (key, value, updatedAt, deletedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt, deletedAt = excluded.deletedAt
                """, arguments: [key, value, now, value == nil ? now : nil])
        }
    }

    private static func nextOrder(_ db: Database, table: String, column: String) throws -> Double {
        (try Double.fetchOne(db, sql: "SELECT MAX(\(column)) FROM \(table)") ?? -1) + 1
    }

    // MARK: - Миграции

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "taskList") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("isInbox", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .double).notNull()
                t.column("sortMode", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "listSection") { t in
                t.primaryKey("id", .blob)
                t.column("listId", .blob).notNull().indexed().references("taskList")
                t.column("name", .text).notNull()
                t.column("sortOrder", .double).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "priority") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("sortOrder", .double).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "taskItem") { t in
                t.primaryKey("id", .blob)
                t.column("listId", .blob).notNull().indexed().references("taskList")
                t.column("sectionId", .blob).references("listSection")
                t.column("title", .text).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("priorityId", .blob).references("priority")
                t.column("plannedDay", .text)
                t.column("deadlineDay", .text)
                t.column("durationMinutes", .integer)
                t.column("manualOrder", .double).notNull()
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "tag") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(table: "taskTag") { t in
                t.column("taskId", .blob).notNull().references("taskItem")
                t.column("tagId", .blob).notNull().references("tag")
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.primaryKey(["taskId", "tagId"])
            }
            try db.create(table: "blocker") { t in
                t.primaryKey("id", .blob)
                t.column("taskId", .blob).notNull().indexed().references("taskItem")
                t.column("blockingTaskId", .blob).indexed().references("taskItem")
                t.column("reason", .text)
                t.column("sinceDay", .text).notNull()
                t.column("resolvedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.check(sql: "(blockingTaskId IS NULL) <> (reason IS NULL)")
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }

            // Система «Путь джедая»: Inbox и приоритеты по умолчанию
            // Сырым SQL: структуры моделей знают о колонках из более поздних миграций
            let now = Date()
            try db.execute(sql: "INSERT INTO taskList (id, name, isInbox, sortOrder, sortMode, createdAt, updatedAt) VALUES (?, 'Inbox', 1, 0, 'manual', ?, ?)",
                           arguments: [UUID(), now, now])
            let defaults = [("1 — ближайшие дни", "#E5484D"), ("5 — неделя–две", "#F5A524"), ("9 — когда-нибудь", "#3E9BF0")]
            for (index, (name, color)) in defaults.enumerated() {
                try db.execute(sql: "INSERT INTO priority (id, name, colorHex, sortOrder, updatedAt) VALUES (?, ?, ?, ?, ?)",
                               arguments: [UUID(), name, color, Double(index), now])
            }
        }

        migrator.registerMigration("v2-import") { db in
            try db.alter(table: "taskItem") { t in t.add(column: "externalId", .text) }
            try db.create(index: "taskItem_externalId", on: "taskItem", columns: ["externalId"])
        }

        migrator.registerMigration("v3-colors") { db in
            try db.alter(table: "taskList") { t in t.add(column: "colorHex", .text).notNull().defaults(to: TaskList.palette[0]) }
            try db.alter(table: "priority") { t in t.add(column: "marks", .text).notNull().defaults(to: "!") }
            // Уровни по умолчанию: важнее — больше восклицательных знаков
            let ids = try UUID.fetchAll(db, sql: "SELECT id FROM priority WHERE deletedAt IS NULL ORDER BY sortOrder")
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE priority SET marks = ? WHERE id = ?", arguments: [String(repeating: "!", count: max(1, 3 - index)), id])
            }
        }

        migrator.registerMigration("v4-icons") { db in
            try db.alter(table: "taskList") { t in t.add(column: "icon", .text).notNull().defaults(to: TaskList.icons[0]) }
            try db.execute(sql: "UPDATE taskList SET icon = 'tray.fill' WHERE isInbox = 1")
        }

        migrator.registerMigration("v5-prune-tags") { db in
            // Уборка тегов, набежавших от сохранения на каждую букву
            try pruneTags(db, now: Date())
        }

        return migrator
    }
}
