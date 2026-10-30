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
