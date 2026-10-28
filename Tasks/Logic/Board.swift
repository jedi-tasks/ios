import Foundation

/// Задача со всем, что нужно для строки списка.
struct TaskRow: Identifiable, Hashable, Sendable {
    var task: TaskItem
    var priority: Priority?
    /// Цвет списка задачи — им красится чекбокс.
    var listColorHex: String = TaskList.palette[0]
    var tags: [Tag]
    var blockers: [Blocker]

    var id: UUID { task.id }
    var isBlocked: Bool { blockers.contains(where: \.isActive) }
    var isDone: Bool { task.completedAt != nil }
}

/// Снимок всех живых данных. Объёмы личного трекера маленькие — фильтруем в памяти.
struct Board: Sendable {
    var lists: [TaskList] = []
    var sections: [ListSection] = []
    var priorities: [Priority] = []
    /// Справочник длительностей по возрастанию, «непрогнозируемо долго» — в конце.
    var durations: [DurationOption] = []
    var tags: [Tag] = []
    var rows: [TaskRow] = []

    var inbox: TaskList? { lists.first(where: \.isInbox) }
    var userLists: [TaskList] { lists.filter { !$0.isInbox } }

    func list(_ id: UUID) -> TaskList? { lists.first { $0.id == id } }
    func sections(of listId: UUID) -> [ListSection] { sections.filter { $0.listId == listId } }
    func row(_ id: UUID) -> TaskRow? { rows.first { $0.id == id } }

    func rows(in listId: UUID, done: Bool) -> [TaskRow] {
        rows.filter { $0.task.listId == listId && $0.isDone == done }
    }

    /// «В планах»: невыполненные со сроком, по дням; всё прошедшее схлопнуто в один день-«просрочено».
    func planned(_ today: String) -> [(day: String, rows: [TaskRow])] {
        let dated = rows.compactMap { row -> (String, TaskRow)? in
            guard !row.isDone, let day = row.task.plannedDay ?? row.task.deadlineDay else { return nil }
            return (day < today ? "0000-00-00" : day, row)
        }
        return Dictionary(grouping: dated, by: \.0)
            .map { (day: $0.key, rows: TaskOrdering.sorted($0.value.map(\.1), by: .priority)) }
            .sorted { $0.day < $1.day }
    }

    /// Поиск по названию и описанию во всех списках; невыполненные — выше.
    func search(_ query: String) -> [TaskRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let found = rows.filter { $0.task.title.localizedCaseInsensitiveContains(q) || $0.task.notes.localizedCaseInsensitiveContains(q) }
        return found.filter { !$0.isDone } + found.filter(\.isDone)
    }

    /// «Сегодня»: невыполненные с планируемым сроком или дедлайном не позже сегодня.
    func today(_ today: String, mode: SortMode) -> [TaskRow] {
        let due = rows.filter { row in
            guard !row.isDone else { return false }
            let planned = row.task.plannedDay.map { $0 <= today } ?? false
            let deadline = row.task.deadlineDay.map { $0 <= today } ?? false
            return planned || deadline
        }
        return TaskOrdering.sorted(due, by: mode, blockedLast: true)
    }
}
