import SwiftUI

/// Строка задачи: чекбокс, название и мета (приоритет, сроки, длительность, теги, блокер).
struct TaskRowView: View {
    let row: TaskRow
    var showList: String?
    /// В «Сегодня» планируемый срок на сегодня очевиден — не показываем.
    var hidesTodayDate = false
    /// В плане по дням день задачи и так виден в заголовке.
    var hidesPlannedDay = false
    /// Для меню «назначить»: списки, приоритеты, теги.
    var board: Board?
    @Environment(\.database) private var database
    @Environment(\.taskSelection) private var selection
    @State private var errors = ErrorAlert()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Тот же кружок в режиме выбора отмечает задачу
            if let selection, selection.isSelecting {
                Button { selection.toggle(row.id) } label: {
                    CheckCircle(done: selection.selected.contains(row.id), selectedStyle: true)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    errors.run { try database.setCompleted(row.id, !row.isDone) }
                } label: {
                    CheckCircle(done: row.isDone)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Приоритет — отдельно, знаками перед названием, как в Напоминаниях
                (priorityMarks + Text(row.task.title).foregroundStyle(row.isDone ? .secondary : .primary))
                    .strikethrough(row.isDone)
                meta
            }
        }
        .opacity(row.isBlocked && !row.isDone ? 0.5 : 1)
        // Бросить на список, приоритет, тег, длительность или день — задача примет значение.
        // Без contextMenu: оно перехватывает долгое нажатие, и перетаскивание не начинается.
        .draggable(row.id.uuidString) { Text(row.task.title).padding(8).background(.regularMaterial, in: Capsule()) }
        .errorAlert(errors)
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
        if let day = row.task.plannedDay, !hidesPlannedDay, !(hidesTodayDate && day == today) {
            items.append(Meta(text: DayKey.short(day), icon: "calendar", color: day < today ? .red : .secondary))
        }
        if let day = row.task.deadlineDay {
            items.append(Meta(text: DayKey.short(day), icon: "flag", color: day <= today ? .red : .secondary))
        }
        if let minutes = row.task.durationMinutes { items.append(Meta(text: Self.duration(minutes), icon: "clock", color: .secondary)) }
        if !row.tags.isEmpty { items.append(Meta(text: row.tags.map(\.name).joined(separator: ", "), icon: "tag", color: .secondary)) }
        return items
    }

    static func duration(_ minutes: Int) -> String { Workload.format(minutes) }
}

/// Чекбокс задачи: всегда серый и тонкий, как в Напоминаниях.
struct CheckCircle: View {
    var done = false
    /// В режиме выбора отметка — цветом выделения, а не серая.
    var selectedStyle = false

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.title3.weight(.ultraLight))
            .foregroundStyle(done && selectedStyle ? Color.accentColor : .gray)
    }
}
