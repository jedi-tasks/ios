import SwiftUI

/// «В планах» — планировщик дней: две недели вперёд, у каждого дня загрузка относительно дневного лимита.
/// Одна лента `TaskCollection` с заголовками дней: задачу можно перетащить в другой день или добавить прямо в день.
struct PlannedScreen: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var addingDay: String?
    @State private var showsOverdue = true
    @State private var errors = ErrorAlert()
    @AppStorage("dailyCapacityMinutes") private var capacity = 360

    var body: some View {
        let (items, days) = content(today: DayKey.today)
        TaskCollection(items: items, board: board) { payload, previous, _ in
            // Бросок встаёт в день элемента над ним; в «Просрочено» — нельзя
            guard let previous, let day = days[previous] else { return false }
            let ids = payload.flatMap(DragPayload.taskIds)
            errors.run { for id in ids { try database.assign(.plannedDay(day), to: id) } }
            return !ids.isEmpty
        }
        .navigationTitle("В планах")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .taskSelection(board: board)
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }

    /// Элементы ленты и день каждого элемента (у просроченных дня нет).
    private func content(today: String) -> ([TaskCollectionItem], [String: String]) {
        var items: [TaskCollectionItem] = []
        var days: [String: String] = [:]
        let overdue = board.overdue(today)
        if !overdue.isEmpty {
            items.append(.view(id: "day:overdue", AnyView(
                DayHeader(title: "Просрочено", subtitle: Workload(overdue).summary, isAlert: true) {
                    Button(showsOverdue ? "Свернуть" : "Показать") { withAnimation { showsOverdue.toggle() } }
                        .font(.subheadline)
                }
            )))
            if showsOverdue { items += overdue.map { .task($0, showList: board.list($0.task.listId)?.name) } }
        }
        for plan in board.planDays(from: today) {
            let load = Workload(plan.rows)
            let header = "day:" + plan.day
            items.append(.view(id: header, AnyView(
                DayHeader(title: Self.title(plan.day, today: today), subtitle: load.summary,
                          load: plan.rows.isEmpty ? nil : Double(load.minutes) / Double(max(capacity, 1))) {
                    Button("Добавить", systemImage: "plus") { addingDay = plan.day }
                        .labelStyle(.iconOnly)
                }
            )))
            days[header] = plan.day
            for row in plan.rows {
                items.append(.task(row, showList: board.list(row.task.listId)?.name, hidesPlannedDay: true))
                days["task:" + row.id.uuidString] = plan.day
            }
            if addingDay == plan.day {
                let id = "new:" + plan.day
                items.append(.view(id: id, AnyView(
                    NewTaskRow(colorHex: board.inbox?.colorHex ?? TaskList.palette[0]) { title in
                        errors.run { try database.addTask(title: title, listId: nil, plannedDay: plan.day) }
                    } onEnd: {
                        if addingDay == plan.day { addingDay = nil }
                    }
                )))
                days[id] = plan.day
            }
        }
        return (items, days)
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

/// Заголовок дня: название, сумма времени, полоска загрузки и кнопка.
private struct DayHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    var isAlert = false
    /// Доля дневного лимита; больше 1 — перегруз.
    var load: Double?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold()).foregroundStyle(isAlert ? .red : .primary)
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
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}
