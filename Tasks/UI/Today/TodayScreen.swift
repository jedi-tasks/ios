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
        // Тап под задачами — новая задача; ещё тап — закончить ввод
        TaskScroll(onEmptyTap: { adding.toggle() }) {
            // Сколько времени займёт день
            let load = Workload(rows)
            if !load.summary.isEmpty {
                Text(load.summary).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(rows) { row in
                TaskLink(id: row.id) {
                    TaskRowView(row: row, showList: board.list(row.task.listId)?.name, hidesTodayDate: true, board: board)
                }
                // Бросок на задачу — встать перед ней; «Сегодня» переходит на ручной порядок
                .dropDestination(for: String.self) { items, _ in place(items, before: row.id, rows: rows) }
            }
            // Новая задача из «Сегодня» — в Inbox со сроком на сегодня
            if adding {
                NewTaskRow(colorHex: board.inbox?.colorHex ?? TaskList.palette[0]) { title in
                    errors.run { try database.addTask(title: title, listId: nil, plannedDay: today) }
                } onEnd: {
                    adding = false
                }
            }
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

    /// Ставит брошенные задачи перед `target` в видимом порядке «Сегодня».
    private func place(_ items: [String], before target: UUID, rows: [TaskRow]) -> Bool {
        let ids = rows.map(\.id)
        let moved = items.flatMap(DragPayload.taskIds).filter { $0 != target && ids.contains($0) }
        guard !moved.isEmpty else { return false }
        var order = ids.filter { !moved.contains($0) }
        order.insert(contentsOf: moved, at: order.firstIndex(of: target) ?? order.count)
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
