import Foundation
import GRDB
import Testing
@testable import Tasks

extension AppDatabase {
    /// База со справочниками по умолчанию, как их создаёт сервер новому пользователю. Очередь пуста.
    static func makeSeeded() throws -> AppDatabase {
        let db = try makeInMemory()
        try db.writer.write { db in
            try TaskList(name: "Inbox", isInbox: true, icon: "tray.fill").insert(db)
            let defaults = [("1 — ближайшие дни", "#E5484D", "!!!"), ("5 — неделя–две", "#F5A524", "!!"), ("9 — когда-нибудь", "#3E9BF0", "!")]
            for (index, (name, color, marks)) in defaults.enumerated() {
                try Priority(name: name, colorHex: color, marks: marks, sortOrder: Double(index)).insert(db)
            }
            for option in TaskDuration.allCases {
                try DurationOption(title: option.title, minutes: option.minutes).insert(db)
            }
        }
        return db
    }

    func queuedMutations() throws -> [Mutation] { try queue().compactMap(\.mutation) }
}

struct SyncQueueTests {
    private let db = try! AppDatabase.makeSeeded()

    private func kinds() throws -> [String] {
        try db.queuedMutations().map { "\($0)".components(separatedBy: "(").first! }
    }

    @Test func newTaskGoesToQueue() throws {
        try db.addTask(title: "A", listId: nil)
        #expect(try kinds() == ["createTask"])
    }

    @Test func consecutiveEditsMerge() throws {
        var task = try db.addTask(title: "A", listId: nil)
        try db.removeQueued(try db.queue()[0].id!)
        task.title = "AB"; task = try db.saveTask(task)
        task.title = "ABC"; task = try db.saveTask(task)
        let queued = try db.queuedMutations()
        #expect(queued.count == 1)
        if case .updateTask(let t) = queued[0] { #expect(t.title == "ABC") } else { Issue.record("не update") }
    }

    @Test func completingResolvesBlockersThroughQueue() throws {
        let a = try db.addTask(title: "A", listId: nil)
        let b = try db.addTask(title: "B", listId: nil)
        try db.addBlocker(task: b.id, blockingTask: a.id)
        try db.setCompleted(a.id, true)
        #expect(try kinds() == ["createTask", "createTask", "createBlocker", "setCompleted", "resolveBlocker"])
    }

    @Test func deletingTaskQueuesChildrenFirst() throws {
        let a = try db.addTask(title: "A", listId: nil)
        let b = try db.addTask(title: "B", listId: nil)
        try db.saveTask(a, tags: ["дом"])
        try db.addBlocker(task: b.id, blockingTask: a.id)
        try db.deleteTask(a.id)
        let tail = Array(try kinds().suffix(4))
        #expect(tail == ["removeTag", "deleteBlocker", "deleteTask", "deleteTag"])
    }

    @Test func deletingListQueuesTasksAndSectionsFirst() throws {
        let list = TaskList(name: "L")
        try db.saveList(list)
        try db.saveSection(ListSection(listId: list.id, name: "S"))
        let section = try db.board().sections[0]
        try db.addTask(title: "T", listId: list.id, sectionId: section.id)
        let before = try db.queue().count
        try db.deleteList(list.id)
        let tail = Array(try kinds().dropFirst(before))
        #expect(tail == ["deleteTask", "deleteSection", "deleteList"])
    }

    @Test func deletingSectionOrPriorityUnlinksTasksFirst() throws {
        let inbox = try db.board().inbox!.id
        try db.saveSection(ListSection(listId: inbox, name: "S"))
        let section = try db.board().sections[0]
        let priority = try db.board().priorities[0]
        let task = try db.addTask(title: "T", listId: inbox, sectionId: section.id)
        try db.assign(.priority(priority.id), to: task.id)
        // Как будто очередь ушла на сервер — иначе отвязка сольётся с ещё не отправленным созданием
        for row in try db.queue() { try db.removeQueued(row.id!) }
        try db.deleteSection(section.id)
        try db.deletePriority(priority.id)
        let tail = try kinds()
        #expect(tail == ["updateTask", "deleteSection", "updateTask", "deletePriority"])
    }

    @Test func remoteChangesDoNotOverwritePendingRows() throws {
        var task = try db.addTask(title: "Локально", listId: nil)
        task.title = "С сервера"
        var other = TaskItem(listId: task.listId, title: "Чужая")
        other.updatedAt = Date()
        try db.apply(SyncChanges(tasks: [task, other]), full: false)
        let titles = Set(try db.board().rows.map(\.task.title))
        #expect(titles == ["Локально", "Чужая"])
    }

    @Test func fullSyncDropsRowsUnknownToServer() throws {
        let inbox = try db.board().inbox!
        try db.writer.write { try TaskItem(listId: inbox.id, title: "Призрак").insert($0) }
        try db.apply(SyncChanges(lists: [inbox]), full: true)
        #expect(try db.board().rows.isEmpty)
        #expect(try db.board().inbox != nil)
    }

    @Test func importGoesThroughQueue() throws {
        let reminder = ImportedReminder(externalId: "1", listName: "Работа", title: "Отчёт", notes: "Раздел: Срочно",
                                        dueDay: nil, priority: 0, completedAt: Date())
        _ = try db.importReminders([reminder])
        #expect(try kinds() == ["createList", "createSection", "createTask", "setCompleted"])
    }
}

struct DeletedTaskTests {
    private let db = try! AppDatabase.makeSeeded()

    @Test func savingDeletedDraftDoesNotResurrect() throws {
        let task = try db.addTask(title: "A", listId: nil)
        try db.saveTask(task, tags: ["дом"])
        try db.deleteTask(task.id)
        let count = try db.queue().count
        try db.saveTask(task, tags: ["дом"])
        #expect(try db.queue().count == count)
        #expect(try db.board().rows.isEmpty)
    }
}
