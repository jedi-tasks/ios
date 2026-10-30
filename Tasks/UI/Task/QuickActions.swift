import SwiftUI

/// Раскрытая задача, как в Напоминаниях: название сразу редактируется (курсор в нём), справа — «ⓘ»
/// к полной карточке, ниже — быстрые действия.
struct ExpandedTaskRow: View {
    let row: TaskRow
    let board: Board
    let onCollapse: () -> Void
    @Environment(\.database) private var database
    @Environment(\.openTask) private var openTask
    @State private var title = ""
    @FocusState private var focused: Bool
    @State private var showsActions = false
    @State private var errors = ErrorAlert()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                errors.run { try database.setCompleted(row.id, !row.isDone) }
            } label: { CheckCircle(done: row.isDone) }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // Знаки приоритета остаются на месте — строка выглядит так же, только название редактируется
                    if let priority = row.priority, !priority.marks.isEmpty {
                        Text(priority.marks + " ").bold().foregroundStyle(Color(hex: priority.colorHex))
                    }
                    TextField("Название", text: $title, axis: .vertical)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            save()
                            onCollapse()
                        }
                        // Многострочное поле на iPhone вставляет перенос вместо onSubmit — считаем его «Готово»
                        .onChange(of: title) {
                            guard title.contains(where: \.isNewline) else { return }
                            title = title.filter { !$0.isNewline }
                            save()
                            onCollapse()
                        }
                    Group {
                        if let openTask {
                            Button { openTask(row.id) } label: { Image(systemName: "info.circle").font(.title3) }
                        } else {
                            NavigationLink(value: row.id) { Image(systemName: "info.circle").font(.title3) }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                // Быстрые действия выползают из-под названия
                if showsActions {
                    QuickActions(row: row, board: board)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .clipped()
        }
        .onAppear {
            title = row.task.title
            focused = true
            withAnimation(.snappy) { showsActions = true }
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .onDisappear { save() }
        .errorAlert(errors)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != row.task.title else { return }
        var task = row.task
        task.title = trimmed
        errors.run { _ = try database.saveTask(task) }
    }
}

/// Быстрые действия под раскрытой задачей: приоритет, срок, дедлайн, длительность, список, тег, блокеры, заметка.
/// На кнопках — текущее значение; пустые приглушены.
struct QuickActions: View {
    let row: TaskRow
    let board: Board
    @Environment(\.database) private var database
    @State private var picking: DateKind?
    @State private var pickingBlocker = false
    @State private var blockerReason: String?
    @State private var editingNotes = false
    @State private var errors = ErrorAlert()

    private enum DateKind: Identifiable {
        case planned, deadline
        var id: Self { self }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(board.priorities) { priority in
                        Button("\(priority.marks) \(priority.name)") { assign(.priority(priority.id)) }
                    }
                    Button("Не разобрано") { assign(.priority(nil)) }
                } label: {
                    chip(row.priority.map { "\($0.marks) \($0.name)" } ?? "Приоритет",
                         icon: row.priority == nil ? "exclamationmark" : nil, isSet: row.priority != nil)
                }

                dateMenu(.planned, title: "Срок", icon: "calendar", day: row.task.plannedDay) { assign(.plannedDay($0)) }
                dateMenu(.deadline, title: "Дедлайн", icon: "flag", day: row.task.deadlineDay) { assign(.deadlineDay($0)) }

                Menu {
                    ForEach(board.durations) { option in Button(option.title) { assign(.duration(option.minutes)) } }
                    Button("Без оценки") { assign(.duration(nil)) }
                } label: {
                    chip(row.task.durationMinutes.map(Workload.format) ?? "Длительность", icon: "clock", isSet: row.task.durationMinutes != nil)
                }

                Menu {
                    ForEach(board.lists) { list in Button(list.name) { assign(.list(list.id)) } }
                } label: {
                    chip(board.list(row.task.listId)?.name ?? "Список", icon: "list.bullet", isSet: true)
                }

                if !board.tags.isEmpty {
                    Menu {
                        ForEach(board.tags.filter { tag in !row.tags.contains { $0.id == tag.id } }) { tag in
                            Button(tag.name) { assign(.tag(tag.id)) }
                        }
                    } label: {
                        chip(row.tags.isEmpty ? "Тег" : row.tags.map(\.name).joined(separator: ", "), icon: "number", isSet: !row.tags.isEmpty)
                    }
                }

                blockersMenu

                Button { editingNotes = true } label: {
                    chip("Заметка", icon: "note.text", isSet: !row.task.notes.isEmpty)
                }
                .buttonStyle(.plain)
            }
            .tint(.primary) // не цветом списка
        }
        .sheet(isPresented: $pickingBlocker) {
            BlockerPicker(taskId: row.id, board: board) { blocking in
                errors.run { try database.addBlocker(task: row.id, blockingTask: blocking) }
            }
        }
        .sheet(isPresented: $editingNotes) { NotesSheet(task: row.task) }
        .alert("Чем заблокировано", isPresented: Binding(get: { blockerReason != nil }, set: { if !$0 { blockerReason = nil } })) {
            TextField("Причина", text: Binding(get: { blockerReason ?? "" }, set: { blockerReason = $0 }))
            Button("Добавить") {
                let reason = (blockerReason ?? "").trimmingCharacters(in: .whitespaces)
                if !reason.isEmpty { errors.run { try database.addBlocker(task: row.id, reason: reason) } }
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(item: $picking) { kind in
            DayPickerSheet(title: kind == .planned ? "Срок" : "Дедлайн",
                           day: kind == .planned ? row.task.plannedDay : row.task.deadlineDay) { day in
                assign(kind == .planned ? .plannedDay(day) : .deadlineDay(day))
            }
        }
        .errorAlert(errors)
    }

    /// Активные блокеры — каждый можно снять или удалить; ниже — добавить задачей или причиной.
    private var blockersMenu: some View {
        let active = row.blockers.filter(\.isActive)
        return Menu {
            ForEach(active) { blocker in
                let title = blocker.blockingTaskId.map { board.row($0)?.task.title ?? "Задача удалена" } ?? blocker.reason ?? ""
                Menu(title) {
                    // Блокер-задача снимается сама, когда её выполнят
                    if blocker.reason != nil {
                        Button("Снять", systemImage: "lock.open") { errors.run { try database.resolveBlocker(blocker.id) } }
                    }
                    Button("Удалить", systemImage: "trash", role: .destructive) { errors.run { try database.deleteBlocker(blocker.id) } }
                }
            }
            Section {
                Button("Задачей…", systemImage: "link") { pickingBlocker = true }
                Button("Причиной…", systemImage: "text.alignleft") { blockerReason = "" }
            }
        } label: {
            chip(active.isEmpty ? "Блокер" : "\(active.count)", icon: "lock", isSet: !active.isEmpty)
        }
    }

    private func dateMenu(_ kind: DateKind, title: String, icon: String, day: String?, set: @escaping (String?) -> Void) -> some View {
        Menu {
            Button("Сегодня") { set(DayKey.today) }
            Button("Завтра") { set(DayKey.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)) }
            Button("Выбрать дату…") { picking = kind }
            if day != nil { Button("Убрать", role: .destructive) { set(nil) } }
        } label: {
            chip(day.map(DayKey.short) ?? title, icon: icon, isSet: day != nil)
        }
    }

    /// Без иконки, когда она дублирует значение (знаки приоритета).
    private func chip(_ text: String, icon: String?, isSet: Bool) -> some View {
        Group {
            if let icon { Label(text, systemImage: icon) } else { Text(text) }
        }
            .font(.subheadline)
            .lineLimit(1)
            .foregroundStyle(isSet ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private func assign(_ assignment: AppDatabase.Assignment) {
        errors.run { try database.assign(assignment, to: row.id) }
    }
}

/// Заметка задачи на весь экран: сохраняется по «Готово».
private struct NotesSheet: View {
    let task: TaskItem
    @Environment(\.database) private var database
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var errors = ErrorAlert()

    var body: some View {
        NavigationStack {
            TextEditor(text: $notes)
                .padding(.horizontal)
                .navigationTitle("Заметка")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            var updated = task
                            updated.notes = notes
                            errors.run { _ = try database.saveTask(updated) }
                            dismiss()
                        }
                    }
                }
        }
        .onAppear { notes = task.notes }
        .errorAlert(errors)
    }
}

/// Выбор дня из календаря.
private struct DayPickerSheet: View {
    let title: String
    let day: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker(title, selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            onPick(DayKey.string(from: date))
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { if let day, let value = DayKey.date(from: day) { date = value } }
    }
}
