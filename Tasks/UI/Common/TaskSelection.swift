import SwiftUI

/// Состояние мультивыбора экрана. Своё, а не `EditMode` у `List`: системный режим сбрасывался,
/// а нижняя панель уходила под таббар.
@MainActor
@Observable
final class TaskSelectionState {
    var isSelecting = false
    var selected: Set<UUID> = []
    /// Задача, под которой раскрыта панель быстрых действий.
    var expanded: UUID?

    func toggle(_ id: UUID) {
        if selected.remove(id) == nil { selected.insert(id) }
    }
}

extension EnvironmentValues {
    @Entry var taskSelection: TaskSelectionState? = nil
    /// Снимок данных экрана — для панели быстрых действий.
    @Entry var taskBoard: Board? = nil
}

/// Строка задачи: тап раскрывает под ней быстрые действия (как в Напоминаниях), в режиме выбора — отмечает задачу.
/// Строку можно перетащить на список, плашку или день — задача (или все отмеченные) примет значение.
struct TaskLink<Content: View>: View {
    let id: UUID
    @ViewBuilder let content: Content
    @Environment(\.taskSelection) private var selection
    @Environment(\.taskBoard) private var board

    var body: some View {
        // Под пальцем/курсором — значок, а не вся строка, как в Напоминаниях
        link.onDrag { NSItemProvider(object: DragPayload.tasks(draggedIds) as NSString) } preview: {
            DragBadge(count: draggedIds.count)
        }
    }

    /// Перетаскивается отмеченная задача — значит, все отмеченные, как в Напоминаниях.
    private var draggedIds: [UUID] {
        if let selection, selection.isSelecting, selection.selected.contains(id) { return Array(selection.selected) }
        return [id]
    }

    @ViewBuilder private var link: some View {
        if let selection, selection.isSelecting {
            // Отметку рисует кружок самой строки; тап по любому месту строки — тоже отметка
            Button { selection.toggle(id) } label: { content.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else if let selection, let board, let row = board.row(id) {
            let expanded = selection.expanded == id
            if expanded {
                ExpandedTaskRow(row: row, board: board) { selection.expanded = nil }
            } else {
                // Жест, а не кнопка: без подсветки нажатия — как тап в текстовое поле
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.expanded = id }
            }
        } else {
            NavigationLink(value: id) { content }
        }
    }
}

/// Лента задач на обычной прокрутке, а не на `List`: внутри системного списка не срабатывали
/// тап с раскрытием быстрых действий и бросок задачи на задачу.
struct TaskScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
        }
        .collapsesTaskOnOutsideTap()
    }
}

extension View {
    /// Тап мимо задач закрывает раскрытую задачу. Тапы по строкам и их кнопкам перехватываются ими самими.
    func collapsesTaskOnOutsideTap() -> some View {
        modifier(CollapseOnOutsideTap())
    }
}

private struct CollapseOnOutsideTap: ViewModifier {
    @Environment(\.taskSelection) private var selection

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { if selection?.expanded != nil { selection?.expanded = nil } }
    }
}

/// Значок перетаскиваемых задач: иконка и, если задач несколько, их число.
private struct DragBadge: View {
    let count: Int

    var body: some View {
        Image(systemName: "checklist")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
            .padding(10)
    }
}

/// Мультивыбор задач: «Выбрать» в шапке, снизу над таббаром — действия сразу для всех выбранных.
private struct TaskSelection: ViewModifier {
    let board: Board
    @State private var state = TaskSelectionState()
    @Environment(\.database) private var database
    @State private var errors = ErrorAlert()

    func body(content: Content) -> some View {
        content
            .environment(\.taskSelection, state)
            .environment(\.taskBoard, board)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(state.isSelecting ? "Готово" : "Выбрать") {
                        withAnimation {
                            state.isSelecting.toggle()
                            state.selected = []
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if state.isSelecting {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) { actions }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .disabled(state.selected.isEmpty)
                }
            }
            .errorAlert(errors)
    }

    @ViewBuilder private var actions: some View {
        Text("\(state.selected.count)").bold().foregroundStyle(.secondary)
        let load = Workload(board.rows.filter { state.selected.contains($0.id) })
        if load.minutes > 0 { Text("≈ " + Workload.format(load.minutes)).foregroundStyle(.secondary) }
        Button("Выполнить", systemImage: "checkmark.circle") {
            run { try database.setCompleted($0, true) }
        }
        Menu("Срок", systemImage: "calendar") {
            Button("Сегодня") { assign(.plannedDay(DayKey.today)) }
            Button("Завтра") {
                assign(.plannedDay(DayKey.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)))
            }
            Button("Убрать срок") { assign(.plannedDay(nil)) }
        }
        Menu("Список", systemImage: "list.bullet") {
            ForEach(board.lists) { list in Button(list.name) { assign(.list(list.id)) } }
        }
        Menu("Приоритет", systemImage: "exclamationmark") {
            ForEach(board.priorities) { priority in
                Button("\(priority.marks) \(priority.name)") { assign(.priority(priority.id)) }
            }
            Button("Не разобрано") { assign(.priority(nil)) }
        }
        Menu("Длительность", systemImage: "clock") {
            ForEach(board.durations) { option in
                Button(option.title) { assign(.duration(option.minutes)) }
            }
            Button("Без оценки") { assign(.duration(nil)) }
        }
        if !board.tags.isEmpty {
            Menu("Тег", systemImage: "number") {
                ForEach(board.tags) { tag in Button(tag.name) { assign(.tag(tag.id)) } }
            }
        }
        Button("Удалить", systemImage: "trash", role: .destructive) {
            run { try database.deleteTask($0) }
        }
    }

    private func assign(_ assignment: AppDatabase.Assignment) {
        run { try database.assign(assignment, to: $0) }
    }

    /// Применяет действие ко всем выбранным и выходит из режима выбора.
    private func run(_ action: (UUID) throws -> Void) {
        errors.run { for id in state.selected { try action(id) } }
        state.selected = []
        state.isSelecting = false
    }
}

extension View {
    func taskSelection(board: Board) -> some View {
        modifier(TaskSelection(board: board))
    }
}
