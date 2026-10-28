import SwiftUI

/// Строка задачи: чекбокс, название и мета (приоритет, сроки, длительность, теги, блокер).
struct TaskRowView: View {
    let row: TaskRow
    var showList: String?
    /// В «Сегодня» планируемый срок на сегодня очевиден — не показываем.
    var hidesTodayDate = false
    /// Для меню «назначить»: списки, приоритеты, теги.
    var board: Board?
    @Environment(\.database) private var database
    @State private var errors = ErrorAlert()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                errors.run { try database.setCompleted(row.id, !row.isDone) }
            } label: {
                CheckCircle(done: row.isDone)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                // Приоритет — отдельно, знаками перед названием, как в Напоминаниях
                (priorityMarks + Text(row.task.title).foregroundStyle(row.isDone ? .secondary : .primary))
                    .strikethrough(row.isDone)
                meta
            }
        }
        .opacity(row.isBlocked && !row.isDone ? 0.5 : 1)
        // Бросить на список, приоритет, тег или длительность — задача примет значение
        .draggable(row.id.uuidString) { Text(row.task.title).padding(8).background(.regularMaterial, in: Capsule()) }
        .contextMenu { if let board { assignMenu(board) } }
        .errorAlert(errors)
    }

    /// То же, что перетаскивание, но из меню — для iPhone.
    @ViewBuilder
    private func assignMenu(_ board: Board) -> some View {
        Button("На сегодня", systemImage: "sun.max") { assign(.plannedDay(DayKey.today)) }
        Menu("Список", systemImage: "list.bullet") {
            ForEach(board.lists) { list in
                Button(list.name) { assign(.list(list.id)) }
            }
        }
        Menu("Приоритет", systemImage: "exclamationmark") {
            ForEach(board.priorities) { priority in
                Button("\(priority.marks) \(priority.name)") { assign(.priority(priority.id)) }
            }
            Button("Не разобрано") { assign(.priority(nil)) }
        }
        Menu("Длительность", systemImage: "clock") {
            ForEach(DurationBucket.allCases, id: \.self) { bucket in
                Button(Self.duration(bucket.minutes)) { assign(.duration(bucket.minutes)) }
            }
            Button("Без оценки") { assign(.duration(nil)) }
        }
        if !board.tags.isEmpty {
            Menu("Добавить тег", systemImage: "number") {
                ForEach(board.tags.filter { tag in !row.tags.contains { $0.id == tag.id } }) { tag in
                    Button(tag.name) { assign(.tag(tag.id)) }
                }
            }
        }
    }

    private func assign(_ assignment: AppDatabase.Assignment) {
        errors.run { try database.assign(assignment, to: row.id) }
    }

    private var priorityMarks: Text {
        guard let priority = row.priority, !priority.marks.isEmpty else { return Text("") }
        return Text(priority.marks + " ").bold().foregroundStyle(Color(hex: priority.colorHex))
    }

    @ViewBuilder private var meta: some View {
        let today = DayKey.today
        let items = metaItems(today: today)
        // Список — его цветом, без иконки; остальное — каждое с новой строки
        if let list = showList {
            Text(list).font(.caption).foregroundStyle(Color(hex: row.listColorHex))
        }
        ForEach(items, id: \.text) { item in
            Label(item.text, systemImage: item.icon)
                .font(.caption)
                .foregroundStyle(item.color)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
    }

    private struct Meta { var text: String; var icon: String; var color: Color }

    private func metaItems(today: String) -> [Meta] {
        var items: [Meta] = []
        let blockers = row.blockers.filter(\.isActive)
        if !blockers.isEmpty { items.append(Meta(text: "\(blockers.count)", icon: "lock", color: .orange)) }
        if let day = row.task.plannedDay, !(hidesTodayDate && day == today) {
            items.append(Meta(text: DayKey.short(day), icon: "calendar", color: day < today ? .red : .secondary))
        }
        if let day = row.task.deadlineDay {
            items.append(Meta(text: DayKey.short(day), icon: "flag", color: day <= today ? .red : .secondary))
        }
        if let minutes = row.task.durationMinutes { items.append(Meta(text: Self.duration(minutes), icon: "clock", color: .secondary)) }
        if !row.tags.isEmpty { items.append(Meta(text: row.tags.map(\.name).joined(separator: ", "), icon: "tag", color: .secondary)) }
        return items
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) мин" : (minutes % 60 == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(minutes % 60) мин")
    }
}

/// Чекбокс задачи: всегда серый и тонкий, как в Напоминаниях.
struct CheckCircle: View {
    var done = false

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.title3.weight(.ultraLight))
            .foregroundStyle(.gray)
    }
}
