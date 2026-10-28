import SwiftUI

/// Список: задачи без раздела, затем разделы; выполненные — по переключателю.
struct ListScreen: View {
    let listId: UUID
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var showDone = false
    @State private var adding: NewTaskTarget?
    @State private var editingSections = false
    @State private var errors = ErrorAlert()

    /// Свёрнутые разделы — общие для всех списков, переживают перезапуск.
    @AppStorage("collapsedSections") private var collapsedRaw = ""
    private var collapsedIds: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: UUID) {
        var ids = collapsedIds
        if ids.remove(id.uuidString) == nil { ids.insert(id.uuidString) }
        collapsedRaw = ids.sorted().joined(separator: ",")
    }

    var body: some View {
        let list = board.list(listId)
        let mode = list?.sortMode ?? .manual
        let open = TaskOrdering.sorted(board.rows(in: listId, done: false), by: mode)
        List {
            group(open.filter { $0.task.sectionId == nil }, mode: mode)
            newRow(NewTaskTarget(), list: list)
            ForEach(board.sections(of: listId)) { section in
                let rows = open.filter { $0.task.sectionId == section.id }
                let collapsed = collapsedIds.contains(section.id.uuidString)
                Section {
                    if !collapsed { group(rows, mode: mode) }
                    newRow(NewTaskTarget(sectionId: section.id), list: list)
                } header: {
                    HStack {
                        Button {
                            withAnimation { toggle(section.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                                Text(section.name).font(.title3.bold())
                                if collapsed && !rows.isEmpty { Text("\(rows.count)").foregroundStyle(.secondary) }
                            }
                            .foregroundStyle(.tint)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Добавить", systemImage: "plus") { add(NewTaskTarget(sectionId: section.id)) }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            if showDone {
                let done = board.rows(in: listId, done: true).sorted { ($0.task.completedAt ?? .distantPast) > ($1.task.completedAt ?? .distantPast) }
                Section("Выполненные") { group(done, mode: .plannedDay, movable: false) }
            }
        }
        // Строки на всю ширину с разделителями, как в Напоминаниях
        .listStyle(.plain)
        .navigationTitle(list?.name ?? "")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Сортировка", selection: Binding(
                        get: { mode },
                        set: { new in errors.run { try database.setSortMode(new, list: listId) } }
                    )) {
                        ForEach(SortMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Показывать выполненные", isOn: $showDone)
                    Button("Разделы", systemImage: "rectangle.split.3x1") { editingSections = true }
                } label: {
                    Label("Ещё", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem { Button("Добавить", systemImage: "plus") { add(NewTaskTarget()) } }
        }
        .sheet(isPresented: $editingSections) { SectionsSheet(listId: listId) }
        .tint(list.map { Color(hex: $0.colorHex) })
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }

    /// Новая строка в разделе; свёрнутый раздел при этом разворачивается.
    private func add(_ target: NewTaskTarget) {
        if let id = target.sectionId, collapsedIds.contains(id.uuidString) { toggle(id) }
        adding = target
    }

    @ViewBuilder
    private func newRow(_ target: NewTaskTarget, list: TaskList?) -> some View {
        if adding == target {
            NewTaskRow(colorHex: list?.colorHex ?? TaskList.palette[0]) { title in
                errors.run { try database.addTask(title: title, listId: listId, sectionId: target.sectionId) }
            } onEnd: {
                if adding == target { adding = nil }
            }
        }
    }

    /// Строки группы. В ручном режиме можно перетаскивать — порядок пишется в `manualOrder`.
    @ViewBuilder
    private func group(_ rows: [TaskRow], mode: SortMode, movable: Bool = true) -> some View {
        ForEach(rows) { row in
            NavigationLink(value: row.id) { TaskRowView(row: row) }
                .listRowSeparator(.hidden)
        }
        .onMove(perform: movable && mode == .manual ? { from, to in
            var ids = rows.map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            // Внутри группы переставляем, сохраняя занятые ею значения порядка
            let slots = rows.map(\.task.manualOrder).sorted()
            errors.run {
                for (id, order) in zip(ids, slots) {
                    guard var task = board.row(id)?.task, task.manualOrder != order else { continue }
                    task.manualOrder = order
                    try database.saveTask(task)
                }
            }
        } : nil)
        .onDelete { offsets in
            errors.run { for index in offsets { try database.deleteTask(rows[index].id) } }
        }
    }
}

/// Управление разделами списка: добавить, переименовать, упорядочить, удалить.
struct SectionsSheet: View {
    let listId: UUID
    @Environment(\.database) private var database
    @Environment(\.dismiss) private var dismiss
    @State private var board = Board()
    @State private var newName = ""
    @State private var errors = ErrorAlert()

    var body: some View {
        NavigationStack {
            List {
                let sections = board.sections(of: listId)
                ForEach(sections) { section in
                    TextField("Название", text: Binding(
                        get: { section.name },
                        set: { name in
                            var updated = section
                            updated.name = name
                            errors.run { try database.saveSection(updated) }
                        }
                    ))
                }
                .onMove { from, to in
                    var ids = sections.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    errors.run { try database.reorder(table: "listSection", ids: ids) }
                }
                .onDelete { offsets in
                    errors.run { for index in offsets { try database.deleteSection(sections[index].id) } }
                }
                HStack {
                    TextField("Новый раздел", text: $newName).onSubmit(add)
                    Button("Добавить", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Разделы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        errors.run { try database.saveSection(ListSection(listId: listId, name: name)) }
        newName = ""
    }
}
