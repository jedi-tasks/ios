import Foundation
import Testing
@testable import Tasks

struct AppDatabaseTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func seedsInboxAndPriorities() throws {
        let board = try db.board()
        #expect(board.inbox != nil)
        #expect(board.priorities.map(\.name).first == "1 — ближайшие дни")
    }

    @Test func taskWithoutListGoesToInbox() throws {
        let task = try db.addTask(title: "Зарядить фонарь", listId: nil)
        #expect(task.listId == (try db.board().inbox?.id))
    }

    @Test func completingBlockingTaskResolvesBlocker() throws {
        let first = try db.addTask(title: "A", listId: nil)
        let second = try db.addTask(title: "B", listId: nil)
        try db.addBlocker(task: second.id, blockingTask: first.id)
        #expect(try db.board().row(second.id)!.isBlocked)

        try db.setCompleted(first.id, true)
        #expect(try !db.board().row(second.id)!.isBlocked)
    }

    @Test func textBlockerStaysUntilResolved() throws {
        let task = try db.addTask(title: "A", listId: nil)
        try db.addBlocker(task: task.id, reason: "Ждём ответа")
        let blocker = try #require(try db.board().row(task.id)!.blockers.first)
        #expect(try db.board().row(task.id)!.isBlocked)
        try db.resolveBlocker(blocker.id)
        #expect(try !db.board().row(task.id)!.isBlocked)
    }

    @Test func rejectsBlockerCycle() throws {
        let a = try db.addTask(title: "A", listId: nil)
        let b = try db.addTask(title: "B", listId: nil)
        let c = try db.addTask(title: "C", listId: nil)
        try db.addBlocker(task: b.id, blockingTask: a.id)
        try db.addBlocker(task: c.id, blockingTask: b.id)
        #expect(throws: AppDatabase.BlockerError.self) { try db.addBlocker(task: a.id, blockingTask: c.id) }
        #expect(throws: AppDatabase.BlockerError.self) { try db.addBlocker(task: a.id, blockingTask: a.id) }
    }

    @Test func deletingBlockingTaskDropsBlocker() throws {
        let a = try db.addTask(title: "A", listId: nil)
        let b = try db.addTask(title: "B", listId: nil)
        try db.addBlocker(task: b.id, blockingTask: a.id)
        try db.deleteTask(a.id)
        #expect(try !db.board().row(b.id)!.isBlocked)
    }

    @Test func tagsAreReusedCaseInsensitively() throws {
        let a = try db.addTask(title: "A", listId: nil)
        let b = try db.addTask(title: "B", listId: nil)
        try db.saveTask(a, tags: ["Дом", "срочно"])
        try db.saveTask(b, tags: ["дом"])
        let board = try db.board()
        #expect(board.tags.count == 2)
        #expect(board.row(b.id)!.tags.map(\.name) == ["Дом"])
    }

    @Test func todayIncludesPlannedAndDeadlineAndPutsBlockedLast() throws {
        let blocked = try db.addTask(title: "Заблокирована", listId: nil, plannedDay: "2026-10-28")
        let planned = try db.addTask(title: "Сегодня", listId: nil, plannedDay: "2026-10-28")
        var deadline = try db.addTask(title: "Дедлайн", listId: nil)
        deadline.deadlineDay = "2026-10-27"
        try db.saveTask(deadline)
        try db.addTask(title: "Завтра", listId: nil, plannedDay: "2026-10-29")
        try db.addBlocker(task: blocked.id, reason: "ждём")

        let titles = try db.board().today("2026-10-28", mode: .priority).map(\.task.title)
        #expect(titles == [planned.title, deadline.title, blocked.title])
    }

    @Test func deletingListRemovesItsTasksButNotInbox() throws {
        let list = TaskList(name: "Calories")
        try db.saveList(list)
        try db.addTask(title: "A", listId: list.id)
        try db.deleteList(list.id)
        try db.deleteList(try db.board().inbox!.id)
        let board = try db.board()
        #expect(board.rows.isEmpty)
        #expect(board.inbox != nil)
    }
}

struct TaskOrderingTests {
    private func row(_ title: String, order: Double, priority: Double? = nil, duration: Int? = nil) -> TaskRow {
        var task = TaskItem(listId: UUID(), title: title, durationMinutes: duration)
        task.manualOrder = order
        return TaskRow(task: task, priority: priority.map { Priority(name: "", colorHex: "", sortOrder: $0) }, tags: [], blockers: [])
    }

    @Test func emptyValuesGoLastAndTiesUseManualOrder() {
        let rows = [row("c", order: 0), row("b", order: 2, priority: 1), row("a", order: 1, priority: 1), row("d", order: 3, priority: 0)]
        #expect(TaskOrdering.sorted(rows, by: .priority).map(\.task.title) == ["d", "a", "b", "c"])
        #expect(TaskOrdering.sorted(rows, by: .manual).map(\.task.title) == ["c", "a", "b", "d"])
    }
}

struct ReminderImportTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func parsesServiceLinesAndDuration() {
        let note = ReminderNote.parse("Раздел: Calories\nЗаблокировано: ответом Пети с 20.10\n~15 мин grilling + ~1,5 ч реализация", year: 2026)
        #expect(note.section == "Calories")
        #expect(note.blockerReason == "ответом Пети")
        #expect(note.blockerSinceDay == "2026-10-20")
        #expect(note.durationMinutes == 105)
        #expect(note.body == "~15 мин grilling + ~1,5 ч реализация")
    }

    @Test func parsesIsoBlockerDateAndPlainNotes() {
        let note = ReminderNote.parse("Заблокировано: доступом с 2026-10-01")
        #expect(note.blockerSinceDay == "2026-10-01")
        #expect(ReminderNote.parse("просто текст").durationMinutes == nil)
    }

    private func reminder(_ id: String, list: String, notes: String = "", priority: Int = 0, done: Bool = false) -> ImportedReminder {
        ImportedReminder(externalId: id, listName: list, title: "T\(id)", notes: notes, dueDay: "2026-10-28",
                         priority: priority, completedAt: done ? Date() : nil)
    }

    @Test func importsIntoListsSectionsAndSkipsDuplicates() throws {
        let batch = [
            reminder("1", list: "Inbox"),
            reminder("2", list: "Маленькие проекты", notes: "Раздел: Calories", priority: 1),
            reminder("3", list: "Маленькие проекты", notes: "Раздел: Calories\nЗаблокировано: ждём", priority: 5),
            reminder("4", list: "LeadLinks", priority: 9, done: true),
        ]
        #expect(try db.importReminders(batch) == ImportResult(added: 4, skipped: 0))
        #expect(try db.importReminders(batch) == ImportResult(added: 0, skipped: 4))

        let board = try db.board()
        #expect(board.userLists.map(\.name).sorted() == ["LeadLinks", "Маленькие проекты"])
        #expect(board.sections.map(\.name) == ["Calories"])
        let rows = Dictionary(uniqueKeysWithValues: board.rows.map { ($0.task.externalId!, $0) })
        #expect(rows["1"]!.task.listId == board.inbox!.id)
        #expect(rows["2"]!.priority?.name == "1 — ближайшие дни")
        #expect(rows["3"]!.isBlocked)
        #expect(rows["3"]!.priority?.name == "5 — неделя–две")
        #expect(rows["4"]!.isDone && rows["4"]!.priority?.name == "9 — когда-нибудь")
        #expect(rows["2"]!.task.plannedDay == "2026-10-28")
    }
}

struct ColorsAndMarksTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func defaultPrioritiesHaveExclamationMarks() throws {
        #expect(try db.board().priorities.map(\.marks) == ["!!!", "!!", "!"])
    }

    @Test func rowCarriesListColorAndImportKeepsReminderColor() throws {
        let imported = ImportedReminder(externalId: "x", listName: "Личные", listColorHex: "#FF6482", title: "Зал",
                                        notes: "", dueDay: nil, priority: 0, completedAt: nil)
        _ = try db.importReminders([imported])
        let board = try db.board()
        #expect(board.userLists.first?.colorHex == "#FF6482")
        #expect(board.rows.first?.listColorHex == "#FF6482")
    }
}

struct PlannedTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func groupsByDayWithOverdueFirstAndDeadlineFallback() throws {
        try db.addTask(title: "Вчера", listId: nil, plannedDay: "2026-10-27")
        try db.addTask(title: "Завтра", listId: nil, plannedDay: "2026-10-29")
        var deadline = try db.addTask(title: "Дедлайн", listId: nil)
        deadline.deadlineDay = "2026-10-28"
        try db.saveTask(deadline)
        try db.addTask(title: "Без даты", listId: nil)

        let groups = try db.board().planned("2026-10-28")
        #expect(groups.map(\.day) == ["0000-00-00", "2026-10-28", "2026-10-29"])
        #expect(groups.map { $0.rows.map(\.task.title) } == [["Вчера"], ["Дедлайн"], ["Завтра"]])
        #expect(PlannedScreen.title("0000-00-00", today: "2026-10-28") == "Просрочено")
    }
}

struct AssignmentTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func droppingOnObjectsSetsValues() throws {
        let list = TaskList(name: "LeadLinks")
        try db.saveList(list)
        let task = try db.addTask(title: "A", listId: nil)
        try db.saveTask(task, tags: ["дом"])
        let board = try db.board()
        let high = board.priorities[0]

        try db.assign(.list(list.id), to: task.id)
        try db.assign(.priority(high.id), to: task.id)
        try db.assign(.duration(DurationBucket.h1.minutes), to: task.id)
        try db.assign(.plannedDay("2026-10-28"), to: task.id)
        try db.saveTask(try db.addTask(title: "B", listId: nil), tags: ["срочно"])
        let urgent = try db.board().tags.first { $0.name == "срочно" }!
        try db.assign(.tag(urgent.id), to: task.id)

        let row = try db.board().row(task.id)!
        #expect(row.task.listId == list.id)
        #expect(row.priority?.id == high.id)
        #expect(row.task.durationMinutes == 60)
        #expect(row.task.plannedDay == "2026-10-28")
        #expect(row.tags.map(\.name) == ["дом", "срочно"])
    }

    @Test func filtersMatchBucketsPrioritiesAndTags() throws {
        var task = try db.addTask(title: "A", listId: nil)
        task.durationMinutes = 45
        try db.saveTask(task, tags: ["дом"])
        let board = try db.board()
        #expect(board.rows(matching: .duration(.h1)).count == 1)
        #expect(board.rows(matching: .duration(.m30)).isEmpty)
        #expect(board.rows(matching: .priority(nil)).count == 1)
        #expect(board.rows(matching: .tag(board.tags[0].id)).count == 1)
        #expect(DurationBucket.of(300) == .more && DurationBucket.of(15) == .m15)
    }
}

struct ArrangeTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func arrangeReordersMovesSectionAndSwitchesToManual() throws {
        let list = TaskList(name: "L", sortMode: .priority)
        try db.saveList(list)
        let section = ListSection(listId: list.id, name: "S")
        try db.saveSection(section)
        let a = try db.addTask(title: "A", listId: list.id)
        let b = try db.addTask(title: "B", listId: list.id)
        let c = try db.addTask(title: "C", listId: list.id)

        try db.arrange(list: list.id, order: [c.id, a.id, b.id], moved: [c.id], section: section.id)
        let board = try db.board()
        #expect(board.list(list.id)?.sortMode == .manual)
        #expect(TaskOrdering.sorted(board.rows(in: list.id, done: false), by: .manual).map(\.task.title) == ["C", "A", "B"])
        #expect(board.row(c.id)?.task.sectionId == section.id)
    }
}

struct TagPruneTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func unusedTagsDisappear() throws {
        let task = try db.addTask(title: "A", listId: nil)
        try db.saveTask(task, tags: ["Д"])
        try db.saveTask(task, tags: ["Для души"])
        #expect(try db.board().tags.map(\.name) == ["Для души"])
        try db.deleteTask(task.id)
        #expect(try db.board().tags.isEmpty)
    }
}

struct WorkloadTests {
    private let db = try! AppDatabase.makeInMemory()

    @Test func sumsEstimatesAndCountsUnestimated() throws {
        var a = try db.addTask(title: "A", listId: nil, plannedDay: "2026-10-29")
        a.durationMinutes = 45
        try db.saveTask(a)
        var b = try db.addTask(title: "B", listId: nil, plannedDay: "2026-10-29")
        b.durationMinutes = 90
        try db.saveTask(b)
        try db.addTask(title: "C", listId: nil, plannedDay: "2026-10-29")
        try db.addTask(title: "Old", listId: nil, plannedDay: "2026-10-20")

        let board = try db.board()
        let days = board.planDays(from: "2026-10-28", days: 3)
        #expect(days.map(\.day) == ["2026-10-28", "2026-10-29", "2026-10-30"])
        #expect(days[0].rows.isEmpty)
        let load = Workload(days[1].rows)
        #expect(load.minutes == 135 && load.unestimated == 1)
        #expect(load.summary == "≈ 2 ч 15 мин · 1 без оценки")
        #expect(board.overdue("2026-10-28").map(\.task.title) == ["Old"])
    }
}
