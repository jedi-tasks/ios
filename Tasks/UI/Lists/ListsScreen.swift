import SwiftUI

/// Все списки: Inbox сверху, свои — в произвольном порядке, у каждого свой цвет.
struct ListsScreen: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var editing: TaskList?
    @State private var errors = ErrorAlert()

    var body: some View {
        List {
            if let inbox = board.inbox {
                NavigationLink(value: inbox.id) { ListRowLabel(list: inbox, count: board.rows(in: inbox.id, done: false).count) }
            }
            Section("Списки") {
                ForEach(board.userLists) { list in
                    NavigationLink(value: list.id) { ListRowLabel(list: list, count: board.rows(in: list.id, done: false).count) }
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
        .navigationTitle("Списки")
        .navigationDestination(for: UUID.self) { ListScreen(listId: $0) }
        .toolbar {
            ToolbarItem { EditButton() }
            ToolbarItem { Button("Новый список", systemImage: "plus") { editing = TaskList(name: "") } }
        }
        .sheet(item: $editing) { ListEditSheet(list: $0) }
        .observingBoard($board, in: database)
        .errorAlert(errors)
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
