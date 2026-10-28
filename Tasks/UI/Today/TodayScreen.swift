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
        List {
            ForEach(rows) { row in
                NavigationLink(value: row.id) {
                    TaskRowView(row: row, showList: board.list(row.task.listId)?.name, hidesTodayDate: true, board: board)
                }
                .listRowSeparator(.hidden)
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
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty && !adding { ContentUnavailableView("На сегодня всё", systemImage: "checkmark.seal") }
        }
        .navigationTitle("Сегодня")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .toolbar {
            ToolbarItem { SortMenu(mode: $mode, allowsManual: false) }
            ToolbarItem { Button("Добавить", systemImage: "plus") { adding = true } }
        }
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }
}

struct SortMenu: View {
    @Binding var mode: SortMode
    var allowsManual = true

    var body: some View {
        Menu {
            Picker("Сортировка", selection: $mode) {
                ForEach(SortMode.allCases.filter { allowsManual || $0 != .manual }, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Сортировка", systemImage: "arrow.up.arrow.down")
        }
    }
}
