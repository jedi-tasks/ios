import SwiftUI
import WidgetKit

struct TaskListEntry: TimelineEntry {
    enum Content {
        case tasks(WidgetSnapshot.List, [WidgetSnapshot.Task])
        /// Снимка ещё нет или в нём нет списков: приложение не открывали или вышли из аккаунта.
        case noData
        case listDeleted
    }

    var date: Date
    var content: Content
}

struct TaskListProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TaskListEntry {
        let list = WidgetSnapshot.List(id: UUID(), name: "Inbox", colorHex: "#3E9BF0", icon: "tray", isInbox: true,
                                       sortMode: "manual", tasks: [], orders: [:])
        let tasks = ["Задача", "Ещё задача", "Третья задача"].map {
            WidgetSnapshot.Task(id: UUID(), title: $0, isBlocked: false)
        }
        return TaskListEntry(date: Date(), content: .tasks(list, tasks))
    }

    func snapshot(for configuration: TaskListWidgetIntent, in context: Context) async -> TaskListEntry {
        entry(for: configuration)
    }

    /// Данные обновляет приложение; сам виджет перерисовывается в полночь, чтобы сроки стали просроченными.
    func timeline(for configuration: TaskListWidgetIntent, in context: Context) async -> Timeline<TaskListEntry> {
        let midnight = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0), matchingPolicy: .nextTime)
        return Timeline(entries: [entry(for: configuration)], policy: midnight.map { .after($0) } ?? .never)
    }

    private func entry(for configuration: TaskListWidgetIntent) -> TaskListEntry {
        guard let snapshot = WidgetSnapshot.load(), !snapshot.lists.isEmpty else {
            return TaskListEntry(date: Date(), content: .noData)
        }
        if configuration.list?.id == WidgetSnapshot.todayId, let today = snapshot.today {
            let day = DayKey.today
            let tasks = today.sortedTasks(by: configuration.sort.sortMode).filter { $0.isDue(on: day) }
            return TaskListEntry(date: Date(), content: .tasks(today, tasks))
        }
        let list = configuration.list.map { selected in snapshot.lists.first { $0.id == selected.id } } ?? snapshot.inbox
        guard let list else { return TaskListEntry(date: Date(), content: .listDeleted) }
        return TaskListEntry(date: Date(), content: .tasks(list, list.sortedTasks(by: configuration.sort.sortMode)))
    }
}

extension WidgetSnapshot.Task {
    init(id: UUID, title: String, isBlocked: Bool) {
        self.init(id: id, title: title, priorityMarks: nil, priorityColorHex: nil, plannedDay: nil, deadlineDay: nil, isBlocked: isBlocked)
    }
}

struct TaskListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaskListEntry

    private var maxRows: Int {
        switch family {
        case .systemSmall: 4
        case .systemMedium: 4
        default: 11
        }
    }

    var body: some View {
        switch entry.content {
        case .tasks(let list, let tasks): content(list, tasks).widgetURL(WidgetLink.list(list.id).url)
        case .noData: message("Откройте приложение и войдите в аккаунт")
        case .listDeleted: message("Список удалён. Выберите другой в настройках виджета")
        }
    }

    private func content(_ list: WidgetSnapshot.List, _ tasks: [WidgetSnapshot.Task]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: list.icon).font(.caption.bold())
                Text(list.name).font(.subheadline.bold()).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(tasks.count)").font(.subheadline.bold())
            }
            .foregroundStyle(Color(hex: list.colorHex))
            if tasks.isEmpty {
                Spacer()
                Text("Нет задач").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(tasks.prefix(maxRows)) { task in
                    // В маленьком виджете iOS не поддерживает ссылки на части: нажатие открывает список
                    if family == .systemSmall {
                        row(task, list: list)
                    } else {
                        Link(destination: WidgetLink.task(task.id).url) { row(task, list: list) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ task: WidgetSnapshot.Task, list: WidgetSnapshot.List) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle").font(.footnote).foregroundStyle(Color(hex: list.colorHex))
            title(task).font(.footnote).lineLimit(1)
            if family != .systemSmall, let day = task.plannedDay ?? task.deadlineDay {
                Spacer(minLength: 4)
                Text(DayKey.short(day))
                    .font(.caption2)
                    .foregroundStyle(day < DayKey.string(from: entry.date) ? .red : .secondary)
            }
        }
        .opacity(task.isBlocked ? 0.5 : 1)
    }

    private func title(_ task: WidgetSnapshot.Task) -> Text {
        guard let marks = task.priorityMarks, !marks.isEmpty else { return Text(task.title) }
        let color = task.priorityColorHex.map(Color.init(hex:)) ?? .secondary
        return Text(marks + " ").bold().foregroundStyle(color) + Text(task.title)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
}

struct TaskListWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSnapshot.widgetKind, intent: TaskListWidgetIntent.self, provider: TaskListProvider()) { entry in
            TaskListWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Список задач")
        .description("Задачи выбранного списка в нужном порядке.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct TasksWidgetBundle: WidgetBundle {
    var body: some Widget { TaskListWidget() }
}
