import SwiftUI

/// «В планах»: невыполненные задачи со сроком, по дням — как «Запланировано» в Напоминаниях.
/// День задачи — планируемый срок, а без него — дедлайн. Всё прошедшее — в «Просрочено».
struct PlannedScreen: View {
    @Environment(\.database) private var database
    @State private var board = Board()

    var body: some View {
        let today = DayKey.today
        let groups = board.planned(today)
        List {
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink(value: row.id) {
                            TaskRowView(row: row, showList: board.list(row.task.listId)?.name, hidesTodayDate: true, board: board)
                        }
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(Self.title(group.day, today: today))
                        .font(.title3.bold())
                        .foregroundStyle(group.day < today ? .red : .primary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if groups.isEmpty { ContentUnavailableView("Ничего не запланировано", systemImage: "calendar") }
        }
        .navigationTitle("В планах")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .observingBoard($board, in: database)
    }

    static func title(_ day: String, today: String) -> String {
        if day < today { return "Просрочено" }
        if day == today { return "Сегодня" }
        guard let date = DayKey.date(from: day) else { return day }
        if Calendar.current.isDateInTomorrow(date) { return "Завтра" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
    }
}
