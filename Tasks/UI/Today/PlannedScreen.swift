import SwiftUI

/// «В планах» — планировщик дней: две недели вперёд карточками, у каждого дня загрузка
/// относительно дневного лимита. Задачу можно бросить на день или добавить прямо в день.
/// Построено на прокрутке, а не на `List`, чтобы броски на карточки доходили.
struct PlannedScreen: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var addingDay: String?
    @State private var showsOverdue = true
    @State private var errors = ErrorAlert()
    @AppStorage("dailyCapacityMinutes") private var capacity = 360

    var body: some View {
        let today = DayKey.today
        let overdue = board.overdue(today)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !overdue.isEmpty {
                    DayCard(title: "Просрочено", subtitle: Workload(overdue).summary, isAlert: true) {
                        Button(showsOverdue ? "Свернуть" : "Показать") { withAnimation { showsOverdue.toggle() } }
                            .font(.subheadline)
                    } content: {
                        if showsOverdue { rows(overdue, hidesDay: false) }
                    }
                }
                ForEach(board.planDays(from: today), id: \.day) { plan in
                    let load = Workload(plan.rows)
                    DayCard(title: Self.title(plan.day, today: today), subtitle: load.summary,
                            load: plan.rows.isEmpty ? nil : Double(load.minutes) / Double(max(capacity, 1))) {
                        Button("Добавить", systemImage: "plus") { addingDay = plan.day }
                            .labelStyle(.iconOnly)
                    } content: {
                        rows(plan.rows, hidesDay: true)
                        if addingDay == plan.day {
                            NewTaskRow(colorHex: board.inbox?.colorHex ?? TaskList.palette[0]) { title in
                                errors.run { try database.addTask(title: title, listId: nil, plannedDay: plan.day) }
                            } onEnd: {
                                if addingDay == plan.day { addingDay = nil }
                            }
                        }
                    }
                    .taskDrop(.plannedDay(plan.day))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .collapsesTaskOnOutsideTap()
        .background(Color(.systemGroupedBackground))
        .navigationTitle("В планах")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .taskSelection(board: board)
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }

    @ViewBuilder
    private func rows(_ rows: [TaskRow], hidesDay: Bool) -> some View {
        ForEach(rows) { row in
            TaskLink(id: row.id) {
                TaskRowView(row: row, showList: board.list(row.task.listId)?.name, hidesPlannedDay: hidesDay, board: board)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    static func title(_ day: String, today: String) -> String {
        if day < today { return "Просрочено" }
        guard let date = DayKey.date(from: day) else { return day }
        let weekday = date.formatted(.dateTime.weekday(.wide)).capitalized
        let dayMonth = date.formatted(.dateTime.day().month(.wide))
        if day == today { return "Сегодня, \(dayMonth)" }
        if Calendar.current.isDateInTomorrow(date) { return "Завтра, \(dayMonth)" }
        return "\(weekday), \(dayMonth)"
    }
}

/// Карточка дня: заголовок, сумма времени, полоска загрузки и задачи.
private struct DayCard<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    var isAlert = false
    /// Доля дневного лимита; больше 1 — перегруз.
    var load: Double?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(isAlert ? .red : .primary)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                accessory
            }
            if let load {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule()
                            .fill(load > 1 ? Color.red : load > 0.8 ? Color.orange : Color.accentColor)
                            .frame(width: proxy.size.width * min(load, 1))
                    }
                }
                .frame(height: 4)
            }
            content
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
