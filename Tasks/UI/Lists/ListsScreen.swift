import SwiftUI

/// Все списки (iPhone): Inbox, мои списки, подборки. Устроено как боковая панель на iPad.
struct ListsScreen: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var editing: TaskList?
    @State private var opened: SidebarItem?

    var body: some View {
        ListsPanel(board: board, onOpen: { opened = $0 }, onEdit: { editing = $0 })
            .navigationTitle("Списки")
            .navigationDestination(item: $opened) { item in
                switch item {
                case .list(let id): ListScreen(listId: id)
                case .filter(let filter): FilteredScreen(filter: filter)
                case .today: TodayScreen()
                case .planned: PlannedScreen()
                case .settings: SettingsScreen()
                }
            }
            .toolbar {
                ToolbarItem { Button("Новый список", systemImage: "plus") { editing = TaskList(name: "") } }
            }
            .sheet(item: $editing) { ListEditSheet(list: $0) }
            .observingBoard($board, in: database)
    }
}

/// Иконка списка в цветном кружке, как в Напоминаниях.
struct ListIcon: View {
    let list: TaskList
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: list.icon)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: list.colorHex), in: Circle())
    }
}

struct ListRowLabel: View {
    let list: TaskList
    var count = 0

    var body: some View {
        HStack {
            ListIcon(list: list)
            Text(list.name)
            Spacer()
            if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
        }
    }
}

/// Создание и правка списка: название и цвет.
struct ListEditSheet: View {
    @State var list: TaskList
    @Environment(\.database) private var database
    @Environment(\.dismiss) private var dismiss
    @State private var errors = ErrorAlert()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ListIcon(list: list, size: 88).frame(maxWidth: .infinity)
                    TextField("Название", text: $list.name)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(hex: list.colorHex))
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(TaskList.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 36, height: 36)
                                .overlay { if hex == list.colorHex { Circle().stroke(.secondary, lineWidth: 3).padding(-5) } }
                                .onTapGesture { list.colorHex = hex }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(TaskList.icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(icon == list.icon ? .white : .primary)
                                .frame(width: 36, height: 36)
                                .background(icon == list.icon ? Color(hex: list.colorHex) : Color(.tertiarySystemFill), in: Circle())
                                .onTapGesture { list.icon = icon }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(list.name.isEmpty ? "Новый список" : "Список")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        list.name = list.name.trimmingCharacters(in: .whitespaces)
                        errors.run {
                            try database.saveList(list)
                            dismiss()
                        }
                    }
                    .disabled(list.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .errorAlert(errors)
    }
}
