import SwiftUI

/// Карточка задачи. Правки сохраняются сразу.
struct TaskDetailScreen: View {
    let taskId: UUID
    @Environment(\.database) private var database
    @Environment(\.dismiss) private var dismiss
    @State private var board = Board()
    @State private var draft: TaskItem?
    @State private var tagsText = ""
    @State private var addingTextBlocker: String?
    @State private var pickingBlocker = false
    @State private var errors = ErrorAlert()

    var body: some View {
        Group {
            if let row = board.row(taskId), draft != nil {
                form(row)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .observingBoard($board, in: database)
        .onChange(of: board.row(taskId)?.task.updatedAt, initial: true) {
            // Первая загрузка; дальше черновик — источник правды, чтобы не сбивать ввод
            guard draft == nil, let row = board.row(taskId) else { return }
            draft = row.task
            tagsText = row.tags.map(\.name).joined(separator: ", ")
        }
        .errorAlert(errors)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<TaskItem, T>) -> Binding<T> {
        Binding(
            get: { draft![keyPath: keyPath] },
            set: { value in
                draft![keyPath: keyPath] = value
                save()
            }
        )
    }

    private func save(tags: Bool = false) {
        guard let draft else { return }
        // База может поправить порядок и раздел (при смене списка) — берём сохранённую версию
        errors.run { self.draft = try database.saveTask(draft, tags: tags ? Self.parseTags(tagsText) : nil) }
    }

    static func parseTags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func form(_ row: TaskRow) -> some View {
        Form {
            Section {
                HStack {
                    Button {
                        let done = draft!.completedAt == nil
                        draft!.completedAt = done ? Date() : nil
                        errors.run { try database.setCompleted(taskId, done) }
                    } label: {
                        CheckCircle(done: draft!.completedAt != nil)
                    }
                    .buttonStyle(.plain)
                    TextField("Название", text: binding(\.title), axis: .vertical).font(.headline)
                }
            }

            Section {
                Picker("Список", selection: binding(\.listId)) {
                    ForEach(board.lists) { Text($0.name).tag($0.id) }
                }
                let sections = board.sections(of: draft!.listId)
                if !sections.isEmpty {
                    Picker("Раздел", selection: binding(\.sectionId)) {
                        Text("Без раздела").tag(UUID?.none)
                        ForEach(sections) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Picker("Приоритет", selection: binding(\.priorityId)) {
                    Text("Не разобрано").tag(UUID?.none)
                    ForEach(board.priorities) { priority in
                        Text("\(priority.marks) \(priority.name)").tag(UUID?.some(priority.id))
                    }
                }
            }

            Section {
                DayField(title: "Планируемый срок", icon: "calendar", day: binding(\.plannedDay))
                DayField(title: "Дедлайн", icon: "flag", day: binding(\.deadlineDay))
                DurationField(minutes: binding(\.durationMinutes))
            }

            Section("Теги") {
                TextField("через запятую", text: $tagsText)
                    .textInputAutocapitalization(.never)
                    .onSubmit { save(tags: true) }
                    .onChange(of: tagsText) { save(tags: true) }
                let suggestions = tagSuggestions
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(suggestions) { tag in
                                Button(tag.name) { applySuggestion(tag.name) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
            }

            blockersSection(row)

            Section("Описание") {
                TextEditor(text: binding(\.notes)).frame(minHeight: 160)
            }

            Section {
                Button("Удалить задачу", role: .destructive) {
                    errors.run { try database.deleteTask(taskId) }
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $pickingBlocker) {
            BlockerPicker(taskId: taskId, board: board) { blocking in
                errors.run { try database.addBlocker(task: taskId, blockingTask: blocking) }
            }
        }
        .alert("Чем заблокировано", isPresented: Binding(get: { addingTextBlocker != nil }, set: { if !$0 { addingTextBlocker = nil } })) {
            TextField("Причина", text: Binding(get: { addingTextBlocker ?? "" }, set: { addingTextBlocker = $0 }))
            Button("Добавить") {
                let reason = (addingTextBlocker ?? "").trimmingCharacters(in: .whitespaces)
                if !reason.isEmpty { errors.run { try database.addBlocker(task: taskId, reason: reason) } }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func blockersSection(_ row: TaskRow) -> some View {
        Section {
            ForEach(row.blockers) { blocker in
                BlockerRow(blocker: blocker, board: board)
                    .swipeActions {
                        Button("Удалить", role: .destructive) { errors.run { try database.deleteBlocker(blocker.id) } }
                        if blocker.isActive && blocker.reason != nil {
                            Button("Снять") { errors.run { try database.resolveBlocker(blocker.id) } }.tint(.green)
                        }
                    }
            }
            Menu {
                Button("Задачей", systemImage: "link") { pickingBlocker = true }
                Button("Причиной", systemImage: "text.alignleft") { addingTextBlocker = "" }
            } label: {
                Label("Добавить блокер", systemImage: "lock")
            }
        } header: {
            Text("Блокеры")
        } footer: {
            Text("Блокер-задача снимается сама, когда её выполнят. Причину снимают свайпом.")
        }
    }

    /// Подсказки к последнему вводимому тегу.
    private var tagSuggestions: [Tag] {
        let parts = tagsText.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let current = parts.last ?? ""
        let used = Set(parts.dropLast())
        return board.tags
            .filter { !used.contains($0.name.lowercased()) && $0.name.lowercased() != current }
            .filter { current.isEmpty || $0.name.lowercased().hasPrefix(current) }
            .prefix(8).map { $0 }
    }

    private func applySuggestion(_ name: String) {
        var parts = Self.parseTags(tagsText)
        let typing = !tagsText.trimmingCharacters(in: .whitespaces).hasSuffix(",") && !parts.isEmpty
        if typing { parts.removeLast() }
        parts.append(name)
        tagsText = parts.joined(separator: ", ") + ", "
    }
}

private struct BlockerRow: View {
    let blocker: Blocker
    let board: Board

    var body: some View {
        HStack {
            Image(systemName: blocker.isActive ? "lock.fill" : "lock.open")
                .foregroundStyle(blocker.isActive ? .orange : .green)
            VStack(alignment: .leading) {
                if let id = blocker.blockingTaskId {
                    let row = board.row(id)
                    if let row {
                        NavigationLink(value: id) { Text(row.task.title) }
                    } else {
                        Text("Задача удалена").foregroundStyle(.secondary)
                    }
                } else {
                    Text(blocker.reason ?? "")
                }
                Text("с \(DayKey.short(blocker.sinceDay))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(blocker.isActive ? 1 : 0.5)
    }
}

/// Выбор задачи-блокера: списки → задачи по разделам. Поиск — сразу по всем спискам.
private struct BlockerPicker: View {
    let taskId: UUID
    let board: Board
    let onPick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    ForEach(board.lists) { list in
                        let count = candidates.filter { $0.task.listId == list.id }.count
                        if count > 0 {
                            NavigationLink(value: list.id) { ListRowLabel(list: list, count: count) }
                        }
                    }
                } else {
                    ForEach(candidates.filter { $0.task.title.localizedCaseInsensitiveContains(query) }) { row in
                        pickButton(row, subtitle: board.list(row.task.listId)?.name)
                    }
                }
            }
            .overlay { if candidates.isEmpty { ContentUnavailableView("Нет задач", systemImage: "tray") } }
            .searchable(text: $query, prompt: "Поиск по всем спискам")
            .navigationTitle("Чем заблокировано")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { listId in
                listTasks(listId).navigationTitle(board.list(listId)?.name ?? "")
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }

    /// Задачи списка: без раздела, затем по разделам.
    private func listTasks(_ listId: UUID) -> some View {
        let rows = TaskOrdering.sorted(candidates.filter { $0.task.listId == listId }, by: .manual)
        return List {
            ForEach(rows.filter { $0.task.sectionId == nil }) { pickButton($0) }
            ForEach(board.sections(of: listId)) { section in
                let inSection = rows.filter { $0.task.sectionId == section.id }
                if !inSection.isEmpty {
                    Section(section.name) { ForEach(inSection) { pickButton($0) } }
                }
            }
        }
    }

    private func pickButton(_ row: TaskRow, subtitle: String? = nil) -> some View {
        Button {
            onPick(row.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    CheckCircle()
                    Text(row.task.title).foregroundStyle(.primary)
                }
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).padding(.leading, 28) }
            }
        }
    }

    /// Невыполненные задачи, кроме самой задачи и уже блокирующих её.
    private var candidates: [TaskRow] {
        let existing = Set(board.row(taskId)?.blockers.filter(\.isActive).compactMap(\.blockingTaskId) ?? [])
        return board.rows.filter { $0.id != taskId && !$0.isDone && !existing.contains($0.id) }
    }
}

/// Дата без времени, которую можно снять.
private struct DayField: View {
    let title: String
    let icon: String
    @Binding var day: String?

    var body: some View {
        if let key = day, let date = DayKey.date(from: key) {
            HStack {
                DatePicker(selection: Binding(get: { date }, set: { day = DayKey.string(from: $0) }), displayedComponents: .date) {
                    Label(title, systemImage: icon)
                }
                Button("Убрать", systemImage: "xmark.circle.fill") { day = nil }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        } else {
            Button { day = DayKey.today } label: { Label(title, systemImage: icon) }
        }
    }
}

/// Оценка длительности шагом 15 минут.
private struct DurationField: View {
    @Binding var minutes: Int?

    var body: some View {
        if let value = minutes {
            HStack {
                Stepper(value: Binding(get: { value }, set: { minutes = max(5, $0) }), in: 5...(24 * 60), step: 15) {
                    Label(TaskRowView.duration(value), systemImage: "clock")
                }
                Button("Убрать", systemImage: "xmark.circle.fill") { minutes = nil }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        } else {
            Button { minutes = 30 } label: { Label("Планируемое время", systemImage: "clock") }
        }
    }
}
