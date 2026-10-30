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
        // Тап под задачами — новая задача без раздела; ещё тап — закончить ввод
        TaskCollection(items: items(open: open, list: list), board: board,
                       onEmptyTap: { adding == nil ? add(NewTaskTarget()) : (adding = nil) }) { payload, previous, next in
            drop(payload, previous: previous, next: next, open: open)
        }
        .overlay {
            // Пустой Inbox — цель «Пути джедая», заслуживает поздравления
            if list?.isInbox == true && open.isEmpty && adding == nil && !showDone {
                ContentUnavailableView {
                    Label("Inbox пуст", systemImage: "sparkles")
                        .symbolRenderingMode(.multicolor)
                        .symbolEffect(.bounce, options: .nonRepeating)
                } description: {
                    Text("Всё разобрано. Можно выдохнуть ☕️")
                }
                .allowsHitTesting(false)
            }
        }
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
        .taskSelection(board: board)
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }

    /// Новая строка в разделе; свёрнутый раздел при этом разворачивается.
    private func add(_ target: NewTaskTarget) {
        if let id = target.sectionId, collapsedIds.contains(id.uuidString) { toggle(id) }
        adding = target
    }

    /// Лента: сводка, задачи без раздела, разделы со своими задачами, выполненные.
    private func items(open: [TaskRow], list: TaskList?) -> [TaskCollectionItem] {
        var items: [TaskCollectionItem] = []
        let load = Workload(open)
        if !load.summary.isEmpty {
            items.append(.view(id: "summary", AnyView(
                Text(load.summary).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            )))
        }
        items += open.filter { $0.task.sectionId == nil }.map { .task($0) }
        items += newRow(NewTaskTarget(), list: list)
        for section in board.sections(of: listId) {
            let rows = open.filter { $0.task.sectionId == section.id }
            let collapsed = collapsedIds.contains(section.id.uuidString)
            items.append(.view(id: "section:" + section.id.uuidString, AnyView(sectionHeader(section, count: rows.count, collapsed: collapsed))))
            if !collapsed { items += rows.map { .task($0) } }
            items += newRow(NewTaskTarget(sectionId: section.id), list: list)
        }
        if showDone {
            let done = board.rows(in: listId, done: true).sorted { ($0.task.completedAt ?? .distantPast) > ($1.task.completedAt ?? .distantPast) }
            items.append(.view(id: "done", AnyView(
                Text("Выполненные").font(.title3.bold()).padding(.top, 18).padding(.bottom, 6)
            )))
            items += done.map { .task($0) }
        }
        return items
    }

    private func sectionHeader(_ section: ListSection, count: Int, collapsed: Bool) -> some View {
        HStack {
            Button {
                withAnimation { toggle(section.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(section.name).font(.title3.bold())
                    if collapsed && count > 0 { Text("\(count)").foregroundStyle(.secondary) }
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Добавить", systemImage: "plus") { add(NewTaskTarget(sectionId: section.id)) }
                .labelStyle(.iconOnly)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func newRow(_ target: NewTaskTarget, list: TaskList?) -> [TaskCollectionItem] {
        guard adding == target else { return [] }
        return [.view(id: "new:" + (target.sectionId?.uuidString ?? ""), AnyView(
            NewTaskRow(colorHex: list?.colorHex ?? TaskList.palette[0]) { title in
                errors.run { try database.addTask(title: title, listId: listId, sectionId: target.sectionId) }
            } onEnd: {
                if adding == target { adding = nil }
            }
        ))]
    }

    /// Бросок между элементами ленты: перед задачей — в её раздел; иначе — в конец раздела выше.
    private func drop(_ payload: [String], previous: String?, next: String?, open: [TaskRow]) -> Bool {
        if let next, let id = TaskCollectionItem.taskId(of: next), let row = open.first(where: { $0.id == id }) {
            return place(payload, before: id, section: row.task.sectionId, all: open)
        }
        guard previous != "done" else { return false }
        let section: UUID?
        if let previous, let id = TaskCollectionItem.taskId(of: previous) {
            guard let row = open.first(where: { $0.id == id }) else { return false } // среди выполненных
            section = row.task.sectionId
        } else if let previous, previous.hasPrefix("section:") || previous.hasPrefix("new:") {
            section = UUID(uuidString: String(previous.split(separator: ":", maxSplits: 1).last ?? ""))
        } else {
            section = nil
        }
        return place(payload, before: nil, section: section, all: open)
    }

    /// Переставляет брошенные задачи перед `target` (или в конец раздела) в видимом порядке списка.
    private func place(_ items: [String], before target: UUID?, section: UUID?, all: [TaskRow]) -> Bool {
        let moved = items.flatMap(DragPayload.taskIds).filter { $0 != target }
        guard !moved.isEmpty else { return false }
        // Видимый порядок: без раздела, затем разделы по порядку
        let sectionOrder = [nil] + board.sections(of: listId).map { Optional($0.id) }
        var order = sectionOrder.flatMap { id in all.filter { $0.task.sectionId == id }.map(\.id) }
        order.removeAll { moved.contains($0) }
        let index: Int
        if let target, let position = order.firstIndex(of: target) {
            index = position
        } else {
            // В конец раздела: после его последней задачи, иначе — перед первым следующим разделом
            let rest = sectionOrder.drop { $0 != section }.dropFirst()
            let next = all.first { row in rest.contains(row.task.sectionId) && !moved.contains(row.id) }?.id
            index = next.flatMap { order.firstIndex(of: $0) } ?? order.count
        }
        // Соседи — только из того же раздела: у разных разделов ручные порядки не связаны
        let sectionOf = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.task.sectionId) })
        let after = index > 0 ? order[index - 1] : nil
        let before = index < order.count ? order[index] : nil
        order.insert(contentsOf: moved, at: index)
        errors.run {
            // В ручной сортировке — только перемещённые задачи; иначе видимый порядок становится ручным целиком
            let manual = board.list(listId)?.sortMode == .manual
            let placed = try manual && database.insert(
                moved,
                after: after.flatMap { sectionOf[$0] == section ? $0 : nil },
                before: before.flatMap { sectionOf[$0] == section ? $0 : nil }
            ) { $0.listId = listId; $0.sectionId = section }
            if !placed { try database.arrange(list: listId, order: order, moved: moved, section: section) }
        }
        return true
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
