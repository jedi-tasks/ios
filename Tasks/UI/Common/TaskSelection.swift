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
    /// Рамки строк в координатах ленты — для выбора двумя пальцами.
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]

    func toggle(_ id: UUID) {
        if selected.remove(id) == nil { selected.insert(id) }
    }

    /// Cmd-клик: включает режим выбора и отмечает задачу, как в Напоминаниях.
    func commandToggle(_ id: UUID) {
        if !isSelecting {
            isSelecting = true
            selected = []
            expanded = nil
        }
        toggle(id)
    }

    /// Задача под точкой ленты.
    func row(at point: CGPoint) -> UUID? {
        rowFrames.first { $0.value.contains(point) }?.key
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
    @Environment(\.database) private var database
    /// Сдвиг строки свайпом влево: под ней — кнопка «Удалить».
    @State private var swipe: CGFloat = 0

    /// Отступ между строками: на iPhone строки крупнее и без него слипаются.
    static var verticalPadding: CGFloat { UIDevice.current.userInterfaceIdiom == .phone ? 9 : 6 }

    var body: some View {
        // Под пальцем/курсором — значок, а не вся строка, как в Напоминаниях
        swipeable.onDrag { NSItemProvider(object: DragPayload.tasks(draggedIds) as NSString) } preview: {
            DragBadge(count: draggedIds.count)
        }
        .padding(.vertical, Self.verticalPadding)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TaskScroll<EmptyView>.space)) } action: { frame in
            selection?.rowFrames[id] = frame
        }
        .onDisappear { selection?.rowFrames[id] = nil }
    }

    /// Свайп влево, как в Напоминаниях: открывает «Удалить», длинный свайп — удаляет сразу.
    private var swipeable: some View {
        let width: CGFloat = 80
        return link
            .offset(x: swipe)
            .background(alignment: .trailing) {
                if swipe < 0 {
                    Button { delete() } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.white)
                            .frame(width: max(-swipe, width))
                            .frame(maxHeight: .infinity)
                            .background(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipped()
            .gesture(HorizontalSwipe(enabled: selection?.isSelecting != true && selection?.expanded != id) { dx, ended in
                guard ended else {
                    swipe = min(0, dx + (swipe <= -width ? -width : 0))
                    return
                }
                withAnimation(.snappy) {
                    if swipe < -200 { delete() } else { swipe = swipe < -width / 2 ? -width : 0 }
                }
            })
    }

    private func delete() {
        swipe = 0
        try? database.deleteTask(id)
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
                // Жест, а не кнопка: без подсветки нажатия — как тап в текстовое поле.
                // Cmd-клик — отметить задачу (и войти в режим выбора)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(RowTap { command in
                        if command { selection.commandToggle(id) } else { selection.expanded = id }
                    })
            }
        } else {
            NavigationLink(value: id) { content }
        }
    }
}

/// Лента задач на обычной прокрутке, а не на `List`: внутри системного списка не срабатывали
/// тап с раскрытием быстрых действий и бросок задачи на задачу.
/// Тап по пустому месту под задачами — `onEmptyTap` (новая задача или выход из ввода).
/// Протяжка двумя пальцами по строкам — отмечает задачи, как в Напоминаниях.
struct TaskScroll<Content: View>: View {
    /// Координаты ленты: в них строки сообщают свои рамки.
    static var space: String { "taskScroll" }
    var onEmptyTap: (() -> Void)?
    @ViewBuilder let content: Content
    @Environment(\.taskSelection) private var selection
    @State private var contentBottom: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxY } action: { contentBottom = $0 }
                .padding(.bottom, 80)
                .gesture(TwoFingerSelect { point in
                    guard let selection, let id = selection.row(at: point) else { return }
                    if !selection.isSelecting {
                        selection.isSelecting = true
                        selection.selected = []
                        selection.expanded = nil
                    }
                    selection.selected.insert(id)
                })
        }
        .coordinateSpace(.named(Self.space))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .named(Self.space)) { location in
            if selection?.expanded != nil {
                selection?.expanded = nil
            } else if location.y > contentBottom, selection?.isSelecting != true {
                onEmptyTap?()
            }
        }
    }
}

/// Тап по строке с признаком Cmd. В SwiftUI на iOS у жестов нет модификаторов клавиш — берём их у UIKit.
private struct RowTap: UIGestureRecognizerRepresentable {
    let onTap: (_ command: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer { UITapGestureRecognizer() }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { onTap(recognizer.modifierFlags.contains(.command)) }
    }
}

/// Горизонтальная протяжка одним пальцем. UIKit, а не `DragGesture`: тот внутри прокрутки мешал листать —
/// а этот начинается только при движении вбок, вертикальное отдаётся прокрутке.
private struct HorizontalSwipe: UIGestureRecognizerRepresentable {
    let enabled: Bool
    /// Сдвиг по X от начала и закончился ли жест.
    let onChange: (_ dx: CGFloat, _ ended: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: onChange(dx, false)
        default: onChange(dx, true)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}

/// Протяжка двумя пальцами. Пока она идёт, прокрутка выключена — иначе лента уезжает из-под пальцев.
private struct TwoFingerSelect: UIGestureRecognizerRepresentable {
    /// Точка в координатах ленты, над которой сейчас пальцы.
    let onMove: (CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let scroll = sequence(first: recognizer.view, next: { $0?.superview }).compactMap { $0 as? UIScrollView }.first
        switch recognizer.state {
        case .began:
            scroll?.panGestureRecognizer.isEnabled = false
            onMove(context.converter.location(in: .named(TaskScroll<EmptyView>.space)))
        case .changed:
            onMove(context.converter.location(in: .named(TaskScroll<EmptyView>.space)))
        default:
            scroll?.panGestureRecognizer.isEnabled = true
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
