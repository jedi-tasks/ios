import SwiftUI

/// Боковая панель для iPad и Mac: плитки «Сегодня» и Inbox, ниже — мои списки.
struct SidebarRoot: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var selection: SidebarItem? = .today
    @State private var editing: TaskList?
    @State private var errors = ErrorAlert()

    var body: some View {
        NavigationSplitView {
            ListsPanel(board: board, selection: selection, showsTiles: true,
                       onOpen: { selection = $0 }, onEdit: { editing = $0 })
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
                case .filter(let filter): FilteredScreen(filter: filter)
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
}
