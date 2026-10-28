import SwiftUI

enum SidebarItem: Hashable {
    case today, planned, list(UUID), settings
}

/// Боковая панель для iPad и Mac: плитки «Сегодня» и Inbox, ниже — мои списки.
struct SidebarRoot: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var selection: SidebarItem? = .today
    @State private var editing: TaskList?
    @State private var errors = ErrorAlert()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    HStack(spacing: 12) {
                        tile(.today, title: "Сегодня", icon: "sun.max.fill", color: Color(hex: "#3E9BF0"),
                             count: board.today(DayKey.today, mode: .manual).count)
                        tile(.planned, title: "В планах", icon: "calendar", color: Color(hex: "#E5484D"),
                             count: board.planned(DayKey.today).reduce(0) { $0 + $1.rows.count })
                        if let inbox = board.inbox {
                            tile(.list(inbox.id), title: "Inbox", icon: inbox.icon, color: Color(hex: inbox.colorHex),
                                 count: board.rows(in: inbox.id, done: false).count)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section("Мои списки") {
                    ForEach(board.userLists) { list in
                        ListRowLabel(list: list, count: board.rows(in: list.id, done: false).count)
                            .tag(SidebarItem.list(list.id))
                            .contextMenu {
                                Button("Изменить", systemImage: "pencil") { editing = list }
                                Button("Удалить", systemImage: "trash", role: .destructive) {
                                    errors.run { try database.deleteList(list.id) }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Изменить", systemImage: "pencil") { editing = list }.tint(Color(hex: list.colorHex))
                            }
                    }
                    .onMove { from, to in
                        var ids = board.userLists.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        errors.run { try database.reorder(table: "taskList", ids: ids) }
                    }
                    .onDelete { offsets in
                        errors.run { for index in offsets { try database.deleteList(board.userLists[index].id) } }
                    }
                }
            }
            .navigationTitle("Задачи")
            .toolbar {
                ToolbarItem { Button("Настройки", systemImage: "gearshape") { selection = .settings } }
                ToolbarItem(placement: .bottomBar) {
                    Button { editing = TaskList(name: "") } label: { Label("Добавить список", systemImage: "plus.circle.fill") }
                        .labelStyle(.titleAndIcon)
                }
            }
        } detail: {
            NavigationStack {
                switch selection {
                case .today, nil: TodayScreen()
                case .planned: PlannedScreen()
                case .list(let id): ListScreen(listId: id)
                case .settings: SettingsScreen()
                }
            }
            .id(selection)
        }
        .sheet(item: $editing) { ListEditSheet(list: $0) }
        .observingBoard($board, in: database)
        .errorAlert(errors)
    }

    /// Плитка как в Напоминаниях: иконка, счётчик и название; выбранная — залита цветом.
    private func tile(_ item: SidebarItem, title: String, icon: String, color: Color, count: Int) -> some View {
        let selected = selection == item
        return Button { selection = item } label: {
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
                Text(title).font(.subheadline.bold()).foregroundStyle(selected ? .white : .secondary)
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(10)
            .background(selected ? color : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
