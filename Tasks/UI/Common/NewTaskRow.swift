import SwiftUI

/// Куда добавляется новая задача строкой прямо в списке.
struct NewTaskTarget: Equatable {
    var sectionId: UUID?
}

/// Пустая строка новой задачи, как в Напоминаниях: курсор сразу в ней, ниже — быстрые действия.
/// Enter сохраняет и открывает следующую строку; уход с пустой строки — убирает её.
/// Строку убрали снаружи (тап по пустому месту) — набранное сохраняется.
struct NewTaskRow: View {
    let board: Board
    /// Сохраняет задачу с названием и выбранными действиями; вызывается только для непустого текста.
    let onCommit: (String, [AppDatabase.Assignment]) -> Void
    let onEnd: () -> Void
    /// Черновик для кнопок быстрых действий; без Inbox (до первого синка) показывать их не на чем.
    private let emptyDraft: TaskRow?
    @State private var draft: TaskRow?
    @State private var actions: [AppDatabase.Assignment] = []
    @State private var title = ""
    @State private var pickingDate = false
    @FocusState private var focused: Bool

    /// Без `listId` — в Inbox.
    init(board: Board, listId: UUID? = nil, sectionId: UUID? = nil, plannedDay: String? = nil,
         onCommit: @escaping (String, [AppDatabase.Assignment]) -> Void, onEnd: @escaping () -> Void) {
        self.board = board
        self.onCommit = onCommit
        self.onEnd = onEnd
        emptyDraft = (listId ?? board.inbox?.id).map {
            TaskRow(task: TaskItem(listId: $0, sectionId: sectionId, title: "", plannedDay: plannedDay), priority: nil, tags: [], blockers: [])
        }
        _draft = State(initialValue: emptyDraft)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckCircle()
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: $title)
                    .focused($focused)
                    .submitLabel(.next)
                    .onSubmit {
                        // Пустой Enter — закончить; иначе сохранить и остаться в строке для следующей задачи
                        if title.trimmingCharacters(in: .whitespaces).isEmpty {
                            focused = false
                        } else {
                            commit()
                            // На iPhone Enter всё равно снимает фокус — возвращаем его следующим тактом
                            DispatchQueue.main.async { focused = true }
                        }
                    }
                if let draft {
                    QuickActions(row: draft, board: board, onDraftAssign: apply) { pickingDate = $0 }
                }
            }
        }
        .listRowSeparator(.hidden)
        .onAppear { focused = true }
        .onDisappear(perform: commit)
        .onChange(of: pickingDate) { _, picking in if !picking { focused = true } }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            // Фокус мог уйти на миг (Enter с текстом, выбор даты) — закрываем строку, только если он не вернулся
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard !focused, !pickingDate else { return }
                commit()
                onEnd()
            }
        }
    }

    /// Показывает выбранное на кнопках; в базу действия уйдут вместе с задачей.
    private func apply(_ action: AppDatabase.Assignment) {
        actions.append(action)
        guard var row = draft else { return }
        switch action {
        case .list(let id):
            row.task.listId = id
            row.task.sectionId = nil
        case .priority(let id):
            row.task.priorityId = id
            row.priority = board.priorities.first { $0.id == id }
        case .duration(let minutes): row.task.durationMinutes = minutes
        case .tag(let id): row.tags += board.tags.filter { $0.id == id }
        case .plannedDay(let day): row.task.plannedDay = day
        case .deadlineDay(let day): row.task.deadlineDay = day
        }
        draft = row
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = actions
        title = ""
        actions = []
        draft = emptyDraft
        if !trimmed.isEmpty { onCommit(trimmed, chosen) }
    }
}
