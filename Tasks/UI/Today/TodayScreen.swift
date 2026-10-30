import SwiftUI

/// Задачи с планируемым сроком или дедлайном не позже сегодня; заблокированные — внизу.
struct TodayScreen: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var adding = false
    @State private var errors = ErrorAlert()
    @AppStorage("todaySortMode") private var mode: SortMode = .priority

    var body: some View {
        let today = DayKey.today
        let rows = board.today(today, mode: mode)
        // Тап под задачами — новая задача; ещё тап — закончить ввод.
        // Бросок между задачами — встать туда; «Сегодня» переходит на ручной порядок
        TaskCollection(items: items(rows, today: today), board: board, onEmptyTap: { adding.toggle() }) { payload, _, next in
            place(payload, before: next.flatMap(TaskCollectionItem.taskId(of:)), rows: rows)
        }
        .overlay {
            if rows.isEmpty && !adding { ContentUnavailableView("На сегодня всё", systemImage: "checkmark.seal") }
        }
        .navigationTitle("Сегодня")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .toolbar {
            ToolbarItem { SortMenu(mode: $mode) }
            ToolbarItem { Button("Добавить", systemImage: "plus") { adding = true } }
        }
        .taskSelection(board: board)
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }

    private func items(_ rows: [TaskRow], today: String) -> [TaskCollectionItem] {
        var items: [TaskCollectionItem] = []
        // Сколько времени займёт день
        let load = Workload(rows)
        if !load.summary.isEmpty {
            items.append(.view(id: "summary", AnyView(
                Text(load.summary).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            )))
        }
        items += rows.map { .task($0, showList: board.list($0.task.listId)?.name, hidesTodayDate: true) }
        // Новая задача из «Сегодня» — в Inbox со сроком на сегодня
        if adding {
            items.append(.view(id: "new", AnyView(
                NewTaskRow(colorHex: board.inbox?.colorHex ?? TaskList.palette[0]) { title in
                    errors.run { try database.addTask(title: title, listId: nil, plannedDay: today) }
                } onEnd: {
                    adding = false
                }
            )))
        }
        return items
    }

    /// Ставит брошенные задачи перед `target` (или в конец) в видимом порядке «Сегодня».
    private func place(_ items: [String], before target: UUID?, rows: [TaskRow]) -> Bool {
        let ids = rows.map(\.id)
        let moved = items.flatMap(DragPayload.taskIds).filter { $0 != target && ids.contains($0) }
        guard !moved.isEmpty else { return false }
        var order = ids.filter { !moved.contains($0) }
        order.insert(contentsOf: moved, at: target.flatMap { order.firstIndex(of: $0) } ?? order.count)
        errors.run { try database.permuteOrder(order) }
        mode = .manual
        return true
    }
}

struct SortMenu: View {
    @Binding var mode: SortMode

    var body: some View {
        Menu {
            Picker("Сортировка", selection: $mode) {
                ForEach(SortMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Сортировка", systemImage: "arrow.up.arrow.down")
        }
    }
}
