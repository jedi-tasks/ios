import Foundation
import GRDB
import OSLog

private let logger = Logger(subsystem: "tasks", category: "Database")

struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

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
        let durations = try fetchDurations(db)
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
        return Board(lists: lists, sections: sections, priorities: priorities, durations: durations, tags: tags, rows: rows)
    }

    // MARK: - Запись с очередью синка
    //
    // Каждая правка строки идёт через эти помощники: они пишут строку и ставят правку в очередь
    // в той же транзакции. Сервер не делает скрытых каскадов, поэтому зависимые правки
    // (отвязать задачи, удалить связи) доменные методы ниже ставят раньше родительских.

    /// Создаёт или обновляет строку. Без изменений (кроме `updatedAt`) в очередь ничего не идёт.
    @discardableResult
    static func upsert<R: SyncedRecord>(_ db: Database, _ record: R) throws -> R {
        var record = record
        let existing = try R.fetchOne(db, key: record.id)
        if var existing {
            existing.updatedAt = record.updatedAt
            if existing == record { return record }
        }
        record.updatedAt = SyncClock.now()
        try record.save(db)
        try Outbox.enqueue(db, existing == nil ? R.created(record) : R.updated(record))
        return record
    }

    /// Меняет живую строку замыканием; без изменений ничего не пишет.
    static func modify<R: SyncedRecord>(_ db: Database, _ type: R.Type, _ id: UUID, _ change: (inout R) -> Void) throws {
        guard var record = try R.fetchOne(db, key: id), record.deletedAt == nil else { return }
        change(&record)
        try upsert(db, record)
    }

    static func softDelete<R: SyncedRecord>(_ db: Database, _ type: R.Type, _ id: UUID) throws {
        guard var record = try R.fetchOne(db, key: id), record.deletedAt == nil else { return }
        let now = SyncClock.now()
        record.deletedAt = now
        record.updatedAt = now
        try record.update(db)
        try Outbox.enqueue(db, R.deleted(id, at: now))
    }

    private static func liveIds(_ db: Database, _ table: String, where condition: String, _ arguments: StatementArguments) throws -> [UUID] {
        try UUID.fetchAll(db, sql: "SELECT id FROM \(table) WHERE deletedAt IS NULL AND \(condition)", arguments: arguments)
    }

    // MARK: - Списки и разделы

    func saveList(_ list: TaskList) throws {
        try writer.write { db in
            var list = list
            if try TaskList.fetchOne(db, key: list.id) == nil {
                list.sortOrder = try Self.nextOrder(db, table: "taskList", column: "sortOrder")
            }
            try Self.upsert(db, list)
        }
    }

    /// Удаляет список: сначала его задачи (с их связями и блокерами), потом разделы, потом сам список.
    /// Inbox не удаляется.
    func deleteList(_ id: UUID) throws {
        try writer.write { db in
            guard let list = try TaskList.fetchOne(db, key: id), !list.isInbox, list.deletedAt == nil else { return }
            for taskId in try Self.liveIds(db, "taskItem", where: "listId = ?", [id]) { try Self.deleteTask(db, taskId) }
            for sectionId in try Self.liveIds(db, "listSection", where: "listId = ?", [id]) { try Self.deleteSection(db, sectionId) }
            try Self.softDelete(db, TaskList.self, id)
        }
    }

    /// Ручная расстановка списка после перетаскивания: `order` — все открытые задачи списка в новом порядке,
    /// `moved` переезжают в `section` этого списка. Список переключается на ручную сортировку.
    func arrange(list listId: UUID, order: [UUID], moved: [UUID], section: UUID?) throws {
        try writer.write { db in
            try Self.modify(db, TaskList.self, listId) { $0.sortMode = .manual }
            for id in moved {
                try Self.modify(db, TaskItem.self, id) { $0.listId = listId; $0.sectionId = section }
            }
            for (index, id) in order.enumerated() {
                try Self.modify(db, TaskItem.self, id) { $0.manualOrder = Double(index) }
            }
        }
    }

    func setSortMode(_ mode: SortMode, list id: UUID) throws {
        try writer.write { db in try Self.modify(db, TaskList.self, id) { $0.sortMode = mode } }
    }

    func saveSection(_ section: ListSection) throws {
        try writer.write { db in
            var section = section
            if try ListSection.fetchOne(db, key: section.id) == nil {
                section.sortOrder = try Self.nextOrder(db, table: "listSection", column: "sortOrder")
            }
            try Self.upsert(db, section)
        }
    }

    /// Задачи раздела остаются в списке без раздела: сначала они отвязываются, потом раздел удаляется.
    func deleteSection(_ id: UUID) throws {
        try writer.write { db in try Self.deleteSection(db, id) }
    }

    private static func deleteSection(_ db: Database, _ id: UUID) throws {
        for taskId in try liveIds(db, "taskItem", where: "sectionId = ?", [id]) {
            try modify(db, TaskItem.self, taskId) { $0.sectionId = nil }
        }
        try softDelete(db, ListSection.self, id)
    }

    /// Записывает порядок по индексу в массиве. `table` — taskList, listSection, priority или taskItem.
    func reorder(table: String, ids: [UUID]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                let order = Double(index)
                switch table {
                case "taskList": try Self.modify(db, TaskList.self, id) { $0.sortOrder = order }
                case "listSection": try Self.modify(db, ListSection.self, id) { $0.sortOrder = order }
                case "priority": try Self.modify(db, Priority.self, id) { $0.sortOrder = order }
                case "taskItem": try Self.modify(db, TaskItem.self, id) { $0.manualOrder = order }
                default: throw DatabaseError(message: "Неизвестная таблица \(table)")
                }
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
            try Self.upsert(db, priority)
        }
    }

    /// Задачи с этим приоритетом становятся «не разобрано» — до удаления самого приоритета.
    func deletePriority(_ id: UUID) throws {
        try writer.write { db in
            for taskId in try Self.liveIds(db, "taskItem", where: "priorityId = ?", [id]) {
                try Self.modify(db, TaskItem.self, taskId) { $0.priorityId = nil }
            }
            try Self.softDelete(db, Priority.self, id)
        }
    }

    // MARK: - Длительности

    static func fetchDurations(_ db: Database) throws -> [DurationOption] {
        try DurationOption.filter(Column("deletedAt") == nil).fetchAll(db)
            .sorted { ($0.minutes < 0 ? Int.max : $0.minutes) < ($1.minutes < 0 ? Int.max : $1.minutes) }
    }

    /// Сохраняет значение; если поменялись минуты — задачи со старым значением переходят на новое.
    func saveDuration(_ option: DurationOption) throws {
        try writer.write { db in
            if let old = try DurationOption.fetchOne(db, key: option.id), old.minutes != option.minutes {
                for taskId in try Self.liveIds(db, "taskItem", where: "durationMinutes = ?", [old.minutes]) {
                    try Self.modify(db, TaskItem.self, taskId) { $0.durationMinutes = option.minutes }
                }
            }
            try Self.upsert(db, option)
        }
    }

    /// Задачи удалённого значения переходят к ближайшему оставшемуся (или остаются без оценки).
    func deleteDuration(_ id: UUID) throws {
        try writer.write { db in
            guard let option = try DurationOption.fetchOne(db, key: id), option.deletedAt == nil else { return }
            let rest = try Self.fetchDurations(db).filter { $0.id != id }.map(\.minutes)
            let target = DurationSnap.nearest(option.minutes, in: rest)
            for taskId in try Self.liveIds(db, "taskItem", where: "durationMinutes = ?", [option.minutes]) {
                try Self.modify(db, TaskItem.self, taskId) { $0.durationMinutes = target }
            }
            try Self.softDelete(db, DurationOption.self, id)
        }
    }

    // MARK: - Задачи

    /// Сохраняет задачу и заменяет набор её тегов (по названиям; новые теги создаются).
    @discardableResult
    func saveTask(_ task: TaskItem, tags: [String]? = nil) throws -> TaskItem {
        try writer.write { db in
            var task = task
            let existing = try TaskItem.fetchOne(db, key: task.id)
            // Удалённую задачу не воскрешаем (карточка сохраняет черновик и после удаления)
            if let existing, existing.deletedAt != nil { return existing }
            if existing == nil || existing?.listId != task.listId {
                task.manualOrder = try Self.nextOrder(db, table: "taskItem", column: "manualOrder")
            }
            if let sectionId = task.sectionId,
               try ListSection.fetchOne(db, key: sectionId)?.listId != task.listId {
                task.sectionId = nil
            }
            // Выполнение — отдельная правка (SetTaskCompleted), в Update его нет
            let completedAt = task.completedAt
            task.completedAt = existing?.completedAt
            if existing == nil { task.completedAt = nil }
            task = try Self.upsert(db, task)
            if (completedAt != nil) != (task.completedAt != nil) {
                try Self.setCompleted(db, task.id, completedAt != nil, at: completedAt)
                task = try TaskItem.fetchOne(db, key: task.id) ?? task
            }
            if let tags { try Self.replaceTags(db, task: task.id, names: tags) }
            return task
        }
    }

    /// Новая задача; без списка — в Inbox.
    @discardableResult
    func addTask(title: String, listId: UUID?, sectionId: UUID? = nil, plannedDay: String? = nil) throws -> TaskItem {
        let target = try listId ?? writer.read { db in
            try TaskList.filter(Column("isInbox") == true && Column("deletedAt") == nil).fetchOne(db)?.id
        }
        guard let target else { throw DatabaseError(message: "Нет Inbox: дождитесь синхронизации с сервером") }
        return try saveTask(TaskItem(listId: target, sectionId: sectionId, title: title, plannedDay: plannedDay))
    }

    /// Выполнение снимает блокеры, где задача — блокирующая (сервер сам этого не делает).
    func setCompleted(_ id: UUID, _ completed: Bool) throws {
        try writer.write { db in try Self.setCompleted(db, id, completed) }
    }

    /// `at` — время выполнения для локальной строки (импорт); на сервер уходит время правки.
    private static func setCompleted(_ db: Database, _ id: UUID, _ completed: Bool, at completedAt: Date? = nil) throws {
        guard var task = try TaskItem.fetchOne(db, key: id), task.deletedAt == nil,
              (task.completedAt != nil) != completed else { return }
        let now = SyncClock.now()
        task.completedAt = completed ? (completedAt ?? now) : nil
        task.updatedAt = now
        try task.update(db)
        try Outbox.enqueue(db, .setCompleted(id, completed, at: now))
        if completed { try resolveBlockers(db, by: id) }
    }

    func deleteTask(_ id: UUID) throws {
        try writer.write { db in try Self.deleteTask(db, id) }
    }

    /// Мягкое удаление задачи: сначала её связи с тегами и блокеры (и те, где она блокирующая —
    /// иначе зависнут навсегда), потом сама задача, потом осиротевшие теги.
    private static func deleteTask(_ db: Database, _ id: UUID) throws {
        for tagId in try UUID.fetchAll(db, sql: "SELECT tagId FROM taskTag WHERE taskId = ? AND deletedAt IS NULL", arguments: [id]) {
            try removeTag(db, task: id, tag: tagId)
        }
        for blockerId in try liveIds(db, "blocker", where: "(taskId = ? OR blockingTaskId = ?)", [id, id]) {
            try deleteBlocker(db, blockerId)
        }
        try softDelete(db, TaskItem.self, id)
        try pruneTags(db)
    }

    private static func addTag(_ db: Database, task: UUID, tag: UUID) throws {
        if let link = try TaskTag.fetchOne(db, key: ["taskId": task, "tagId": tag]), link.deletedAt == nil { return }
        let now = SyncClock.now()
        try TaskTag(taskId: task, tagId: tag, updatedAt: now).save(db)
        try Outbox.enqueue(db, .addTag(task: task, tag: tag, at: now))
    }

    private static func removeTag(_ db: Database, task: UUID, tag: UUID) throws {
        guard var link = try TaskTag.fetchOne(db, key: ["taskId": task, "tagId": tag]), link.deletedAt == nil else { return }
        let now = SyncClock.now()
        link.deletedAt = now
        link.updatedAt = now
        try link.update(db)
        try Outbox.enqueue(db, .removeTag(task: task, tag: tag, at: now))
    }

    private static func replaceTags(_ db: Database, task: UUID, names: [String]) throws {
        var tagIds: [UUID] = []
        for name in names.map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            let lower = name.lowercased()
            if let tag = try Tag.filter(Column("deletedAt") == nil).fetchAll(db).first(where: { $0.name.lowercased() == lower }) {
                tagIds.append(tag.id)
            } else {
                tagIds.append(try upsert(db, Tag(name: name)).id)
            }
        }
        let wanted = Set(tagIds)
        let current = Set(try UUID.fetchAll(db, sql: "SELECT tagId FROM taskTag WHERE taskId = ? AND deletedAt IS NULL", arguments: [task]))
        for tagId in current.subtracting(wanted) { try removeTag(db, task: task, tag: tagId) }
        for tagId in tagIds where !current.contains(tagId) { try addTag(db, task: task, tag: tagId) }
        try pruneTags(db)
    }

    /// Теги, не висящие ни на одной живой задаче, удаляются — теги существуют только через задачи.
    static func pruneTags(_ db: Database) throws {
        let orphans = try UUID.fetchAll(db, sql: """
            SELECT id FROM tag WHERE deletedAt IS NULL AND id NOT IN (
                SELECT tt.tagId FROM taskTag tt JOIN taskItem t ON t.id = tt.taskId
                WHERE tt.deletedAt IS NULL AND t.deletedAt IS NULL)
            """)
        for id in orphans { try softDelete(db, Tag.self, id) }
    }

    /// Что можно назначить задаче броском на объект (список, приоритет, тег…) или из меню.
    enum Assignment: Sendable {
        case list(UUID)
        case priority(UUID?)
        case duration(Int?)
        case tag(UUID)
        case plannedDay(String?)
        case deadlineDay(String?)
    }

    func assign(_ assignment: Assignment, to taskId: UUID) throws {
        if case .tag(let tagId) = assignment {
            // Тег добавляется к имеющимся, а не заменяет их
            try writer.write { db in try Self.addTag(db, task: taskId, tag: tagId) }
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
        case .deadlineDay(let day): task.deadlineDay = day
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
                try Self.createBlocker(db, Blocker(taskId: task, blockingTaskId: blockingTask, sinceDay: sinceDay), resolved: done)
            } else {
                try Self.createBlocker(db, Blocker(taskId: task, reason: reason, sinceDay: sinceDay), resolved: false)
            }
        }
    }

    private static func createBlocker(_ db: Database, _ blocker: Blocker, resolved: Bool) throws {
        var blocker = blocker
        blocker.updatedAt = SyncClock.now()
        blocker.resolvedAt = nil
        try blocker.insert(db)
        try Outbox.enqueue(db, .createBlocker(blocker))
        if resolved { try resolveBlocker(db, blocker.id) }
    }

    func resolveBlocker(_ id: UUID) throws {
        try writer.write { db in try Self.resolveBlocker(db, id) }
    }

    private static func resolveBlocker(_ db: Database, _ id: UUID, at resolvedAt: Date? = nil) throws {
        guard var blocker = try Blocker.fetchOne(db, key: id), blocker.isActive else { return }
        let now = SyncClock.now()
        blocker.resolvedAt = resolvedAt ?? now
        blocker.updatedAt = now
        try blocker.update(db)
        try Outbox.enqueue(db, .resolveBlocker(id, at: now))
    }

    func deleteBlocker(_ id: UUID) throws {
        try writer.write { db in try Self.deleteBlocker(db, id) }
    }

    private static func deleteBlocker(_ db: Database, _ id: UUID) throws {
        guard var blocker = try Blocker.fetchOne(db, key: id), blocker.deletedAt == nil else { return }
        let now = SyncClock.now()
        blocker.deletedAt = now
        blocker.updatedAt = now
        try blocker.update(db)
        try Outbox.enqueue(db, .deleteBlocker(id, at: now))
    }

    private static func resolveBlockers(_ db: Database, by taskId: UUID) throws {
        for id in try liveIds(db, "blocker", where: "blockingTaskId = ? AND resolvedAt IS NULL", [taskId]) {
            try resolveBlocker(db, id)
        }
    }

    // MARK: - Импорт из Reminders

    /// Добавляет напоминания, которых ещё нет (по `externalId`, включая удалённые — их не возвращаем).
    /// Списки и разделы находятся по имени или создаются; список Reminders «Inbox» — системный Inbox.
    /// Всё пишется через очередь синка, как обычные правки.
    func importReminders(_ reminders: [ImportedReminder]) throws -> ImportResult {
        try writer.write { db in
            var result = ImportResult()
            let known = Set(try String.fetchAll(db, sql: "SELECT externalId FROM taskItem WHERE externalId IS NOT NULL"))
            let priorities = try Priority.filter(Column("deletedAt") == nil).order(Column("sortOrder")).fetchAll(db)
            var order = try Self.nextOrder(db, table: "taskItem", column: "manualOrder")
            let durationValues = try Self.fetchDurations(db).map(\.minutes)

            for reminder in reminders {
                guard !known.contains(reminder.externalId) else { result.skipped += 1; continue }
                let list = try Self.importList(db, named: reminder.listName, colorHex: reminder.listColorHex)
                let note = ReminderNote.parse(reminder.notes)
                let section = try note.section.map { try Self.importSection(db, named: $0, in: list.id) }
                let now = SyncClock.now()
                let task = try Self.upsert(db, TaskItem(
                    listId: list.id,
                    sectionId: section?.id,
                    title: reminder.title,
                    notes: note.body,
                    priorityId: Self.priority(for: reminder.priority, in: priorities)?.id,
                    plannedDay: reminder.dueDay,
                    durationMinutes: note.durationMinutes.flatMap { DurationSnap.nearest($0, in: durationValues) },
                    manualOrder: order,
                    externalId: reminder.externalId,
                    createdAt: now,
                    updatedAt: now
                ))
                order += 1
                if let completedAt = reminder.completedAt { try Self.setCompleted(db, task.id, true, at: completedAt) }
                if let reason = note.blockerReason {
                    try Self.createBlocker(db, Blocker(taskId: task.id, reason: reason, sinceDay: note.blockerSinceDay ?? DayKey.today),
                                           resolved: reminder.completedAt != nil)
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
        return try upsert(db, TaskList(name: name, colorHex: colorHex ?? TaskList.palette[0], sortOrder: try nextOrder(db, table: "taskList", column: "sortOrder")))
    }

    private static func importSection(_ db: Database, named name: String, in listId: UUID) throws -> ListSection {
        let sections = try ListSection.filter(Column("deletedAt") == nil && Column("listId") == listId).fetchAll(db)
        if let section = sections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return section }
        return try upsert(db, ListSection(listId: listId, name: name, sortOrder: try nextOrder(db, table: "listSection", column: "sortOrder")))
    }

    // MARK: - Настройки

    static func setting(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ? AND deletedAt IS NULL", arguments: [key])
    }

    /// Локальная настройка (не уходит на сервер).
    func setSetting(_ key: String, _ value: String?) throws {
        try writer.write { db in try Self.setSetting(db, key, value) }
    }

    static func setSetting(_ db: Database, _ key: String, _ value: String?) throws {
        let now = Date()
        try db.execute(sql: """
            INSERT INTO setting (key, value, updatedAt, deletedAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt, deletedAt = excluded.deletedAt
            """, arguments: [key, value, now, value == nil ? now : nil])
    }

    /// Дневной лимит загрузки — серверная настройка пользователя.
    func setDailyCapacity(_ minutes: Int) throws {
        try writer.write { db in try Outbox.enqueue(db, .updateSettings(dailyCapacityMinutes: minutes, at: SyncClock.now())) }
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

            // Inbox, приоритеты и длительности по умолчанию создаёт сервер — клиент получает их первым синком
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
            try db.execute(sql: """
                UPDATE tag SET deletedAt = ?, updatedAt = ?
                WHERE deletedAt IS NULL AND id NOT IN (
                    SELECT tt.tagId FROM taskTag tt JOIN taskItem t ON t.id = tt.taskId
                    WHERE tt.deletedAt IS NULL AND t.deletedAt IS NULL)
                """, arguments: [Date(), Date()])
        }

        migrator.registerMigration("v6-fixed-durations") { db in
            // Длительности — фиксированный набор: старые значения — к ближайшему
            let rows = try Row.fetchAll(db, sql: "SELECT id, durationMinutes FROM taskItem WHERE durationMinutes IS NOT NULL")
            for row in rows {
                let minutes: Int = row["durationMinutes"]
                let snapped = TaskDuration.of(minutes).minutes
                if snapped != minutes {
                    try db.execute(sql: "UPDATE taskItem SET durationMinutes = ? WHERE id = ?", arguments: [snapped, row["id"] as UUID])
                }
            }
        }

        migrator.registerMigration("v7-duration-options") { db in
            try db.create(table: "durationOption") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("minutes", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
        }

        migrator.registerMigration("v8-sync") { db in
            // Очередь правок для сервера, по порядку записи
            try db.create(table: "syncQueue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entityKey", .text).notNull().indexed()
                t.column("payload", .blob).notNull()
                t.column("tryCount", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("inFlight", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
