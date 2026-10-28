import SwiftUI

/// Что открыть из панели списков: на iPhone — экран, на iPad и Mac — правую колонку.
enum SidebarItem: Hashable {
    case today, planned, list(UUID), filter(TaskFilter), settings
}

/// Панель списков на обычной прокрутке, а не на `List`: системный список перехватывает перетаскивание,
/// и броски на строки и плашки до нас не доходили.
/// Что можно: тап — открыть; бросить задачу — назначить; перетащить список — переставить; меню — изменить, удалить.
struct ListsPanel: View {
    let board: Board
    var selection: SidebarItem?
    /// Плитки «Сегодня / В планах / Inbox» — для боковой панели; на iPhone они во вкладках.
    var showsTiles = false
    let onOpen: (SidebarItem) -> Void
    let onEdit: (TaskList) -> Void
    @Environment(\.database) private var database
    @State private var errors = ErrorAlert()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showsTiles {
                    tiles.padding(.bottom, 12)
                } else if let inbox = board.inbox {
                    ListPanelRow(list: inbox, count: board.rows(in: inbox.id, done: false).count,
                                 isSelected: selection == .list(inbox.id), onOpen: { onOpen(.list(inbox.id)) },
                                 onEdit: nil, onDelete: nil, onDropLists: nil)
                        .padding(.bottom, 12)
                }
                if !board.userLists.isEmpty { header("Мои списки") }
                ForEach(board.userLists) { list in
                    ListPanelRow(
                        list: list,
                        count: board.rows(in: list.id, done: false).count,
                        isSelected: selection == .list(list.id),
                        onOpen: { onOpen(.list(list.id)) },
                        onEdit: { onEdit(list) },
                        onDelete: { errors.run { try database.deleteList(list.id) } },
                        onDropLists: { moved in reorder(moved, before: list.id) }
                    )
                }
                SmartSections(board: board, selected: {
                    if case .filter(let filter) = selection { return filter }
                    return nil
                }()) { onOpen(.filter($0)) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(panelBackground)
        .errorAlert(errors)
    }

    /// На Mac боковая панель прозрачная — сквозь неё виден отсвет обоев, как в Напоминаниях.
    private var panelBackground: Color {
        #if targetEnvironment(macCatalyst)
        showsTiles ? .clear : Color(.systemGroupedBackground)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.secondary).padding(.top, 12).padding(.bottom, 4)
    }

    /// Ставит перетащенные списки перед `target`.
    private func reorder(_ moved: [UUID], before target: UUID) {
        var ids = board.userLists.map(\.id).filter { !moved.contains($0) }
        let index = ids.firstIndex(of: target) ?? ids.count
        ids.insert(contentsOf: moved, at: index)
        errors.run { try database.reorder(table: "taskList", ids: ids) }
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            tile(.today, title: "Сегодня", icon: "sun.max.fill", color: Color(hex: "#3E9BF0"),
                 count: board.today(DayKey.today, mode: .manual).count, drop: .plannedDay(DayKey.today))
            tile(.planned, title: "В планах", icon: "calendar", color: Color(hex: "#E5484D"),
                 count: board.planned(DayKey.today).reduce(0) { $0 + $1.rows.count }, drop: nil)
            if let inbox = board.inbox {
                tile(.list(inbox.id), title: "Inbox", icon: inbox.icon, color: Color(hex: inbox.colorHex),
                     count: board.rows(in: inbox.id, done: false).count, drop: .list(inbox.id))
            }
        }
    }

    /// Плитка как в Напоминаниях: иконка, счётчик и название; выбранная — залита цветом.
    private func tile(_ item: SidebarItem, title: String, icon: String, color: Color, count: Int,
                      drop: AppDatabase.Assignment?) -> some View {
        let selected = selection == item
        return Button { onOpen(item) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selected ? color : .white)
                        .frame(width: 30, height: 30)
                        .background(selected ? Color.white : color, in: Circle())
                    Spacer()
                    Text("\(count)").font(.title2.bold())
                }
                Text(title).font(.subheadline.bold()).foregroundStyle(selected ? .white : .secondary).lineLimit(1)
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(10)
            .background(selected ? color : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .taskDrop(drop)
    }
}

/// Строка списка в панели. Перетаскивается сама (для перестановки) и принимает задачи и другие списки.
private struct ListPanelRow: View {
    let list: TaskList
    let count: Int
    let isSelected: Bool
    let onOpen: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    /// `nil` — список нельзя переставлять (Inbox).
    let onDropLists: (([UUID]) -> Void)?
    @Environment(\.database) private var database
    @State private var targeted = false

    var body: some View {
        ListRowLabel(list: list, count: count)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if onDropLists != nil {
                    // Тап — открыть; долгое нажатие — меню; повёл пальцем — перетаскивание списка
                    MenuDragInteraction(payload: { DragPayload.list(list.id) }, title: list.name, colorHex: list.colorHex,
                                        actions: menuActions, onTap: onOpen)
                } else {
                    Color.clear.contentShape(Rectangle()).onTapGesture(perform: onOpen)
                }
            }
        .dropDestination(for: String.self) { items, _ in
            let lists = items.compactMap(DragPayload.listId)
            if !lists.isEmpty, let onDropLists {
                onDropLists(lists)
                return true
            }
            let tasks = items.flatMap(DragPayload.taskIds)
            for id in tasks { try? database.assign(.list(list.id), to: id) }
            return !tasks.isEmpty
        } isTargeted: { targeted = $0 }
    }

    /// Обычный перечень: фон только у выбранного списка и под перетаскиваемой задачей.
    private var menuActions: [UIAction] {
        var actions: [UIAction] = []
        if let onEdit { actions.append(UIAction(title: "Изменить", image: UIImage(systemName: "pencil")) { _ in onEdit() }) }
        if let onDelete {
            actions.append(UIAction(title: "Удалить", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in onDelete() })
        }
        return actions
    }

    private var background: Color {
        if targeted { return Color.accentColor.opacity(0.25) }
        if isSelected { return Color(hex: list.colorHex).opacity(0.2) }
        return .clear
    }
}

/// Что перетаскивается строкой: задачи — `tasks:UUID,UUID` (или голый UUID), список — `list:UUID`.
enum DragPayload {
    static func tasks(_ ids: [UUID]) -> String { "tasks:" + ids.map(\.uuidString).joined(separator: ",") }

    /// Все задачи из строки: при мультивыборе их несколько.
    static func taskIds(_ payload: String) -> [UUID] {
        if payload.hasPrefix("tasks:") {
            return payload.dropFirst(6).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        }
        return taskId(payload).map { [$0] } ?? []
    }

    static func list(_ id: UUID) -> String { "list:" + id.uuidString }

    static func listId(_ payload: String) -> UUID? {
        payload.hasPrefix("list:") ? UUID(uuidString: String(payload.dropFirst(5))) : nil
    }

    static func taskId(_ payload: String) -> UUID? { UUID(uuidString: payload) }
}

/// Цель для задачи: брошенная задача получает значение объекта. Подсвечивается при наведении.
private struct TaskDropTarget: ViewModifier {
    let assignment: AppDatabase.Assignment?
    @Environment(\.database) private var database

    func body(content: Content) -> some View {
        if let assignment {
            content.dropDestination(for: String.self) { items, _ in
                let ids = items.flatMap(DragPayload.taskIds)
                for id in ids { try? database.assign(assignment, to: id) }
                return !ids.isEmpty
            }
        } else {
            content
        }
    }
}

extension View {
    func taskDrop(_ assignment: AppDatabase.Assignment?) -> some View {
        modifier(TaskDropTarget(assignment: assignment))
    }
}
