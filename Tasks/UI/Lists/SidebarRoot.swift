import SwiftUI

/// Боковая панель для iPad и Mac: плитки «Сегодня / В планах / Inbox», ниже — мои списки и подборки.
/// На Mac шапка как у Напоминаний: над панелью — «Новый список», справа — «+» экрана и поиск.
struct SidebarRoot: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var selection: SidebarItem? = .today
    @State private var editing: TaskList?
    @State private var query = ""
    @State private var errors = ErrorAlert()

    var body: some View {
        NavigationSplitView {
            ListsPanel(board: board, selection: selection, showsTiles: true,
                       onOpen: { query = ""; selection = $0 }, onEdit: { editing = $0 })
            .navigationTitle("Задачи")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Новый список", systemImage: "text.badge.plus") { editing = TaskList(name: "") }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Настройки", systemImage: "gearshape") { query = ""; selection = .settings }
                }
            }
        } detail: {
            NavigationStack {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchScreen(query: query)
                } else {
                    switch selection {
                    case .today, nil: TodayScreen()
                    case .planned: PlannedScreen()
                    case .filter(let filter): FilteredScreen(filter: filter)
                    case .list(let id): ListScreen(listId: id)
                    case .settings: SettingsScreen()
                    }
                }
            }
            .id(selection)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Поиск")
        .sheet(item: $editing) { ListEditSheet(list: $0) }
        .observingBoard($board, in: database)
        .errorAlert(errors)
        .modifier(UnifiedTitlebar())
    }
}

/// Найденные задачи по всем спискам: сначала невыполненные.
struct SearchScreen: View {
    let query: String
    @Environment(\.database) private var database
    @State private var board = Board()

    var body: some View {
        let rows = board.search(query)
        List {
            ForEach(rows) { row in
                TaskLink(id: row.id) {
                    TaskRowView(row: row, showList: board.list(row.task.listId)?.name, board: board)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { if rows.isEmpty { ContentUnavailableView.search(text: query) } }
        .navigationTitle("Поиск")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .taskSelection(board: board)
        .observingBoard($board, in: database)
    }
}

/// На Mac — единая шапка без названия окна, как у Напоминаний.
private struct UnifiedTitlebar: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.onAppear {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.toolbarStyle = .unified
            }
        }
        #else
        content
        #endif
    }
}
