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

    /// На Mac над панелью только кнопки — как у Напоминаний.
    #if targetEnvironment(macCatalyst)
    private static let sidebarTitle = ""
    #else
    private static let sidebarTitle = "Задачи"
    #endif

    var body: some View {
        NavigationSplitView {
            ListsPanel(board: board, selection: selection, showsTiles: true,
                       onOpen: { query = ""; selection = $0 }, onEdit: { editing = $0 })
            .navigationTitle(Self.sidebarTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Новый список", systemImage: "text.badge.plus") { editing = TaskList(name: "") }
                }
                #if !targetEnvironment(macCatalyst)
                // На Mac настройки — через меню приложения и Cmd+,
                ToolbarItem(placement: .bottomBar) {
                    Button("Настройки", systemImage: "gearshape") { openSettings() }
                }
                #endif
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
            #if targetEnvironment(macCatalyst)
            .toolbar { ToolbarItem(placement: .primaryAction) { MacSearchField(query: $query) } }
            #endif
        }
        #if !targetEnvironment(macCatalyst)
        .searchable(text: $query, placement: .toolbar, prompt: "Поиск")
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in openSettings() }
        .sheet(item: $editing) { ListEditSheet(list: $0) }
        .observingBoard($board, in: database)
        .errorAlert(errors)
        .modifier(UnifiedTitlebar())
    }

    private func openSettings() {
        query = ""
        selection = .settings
    }
}

extension Notification.Name {
    /// Команда «Настройки…» из меню приложения (Cmd+,).
    static let openSettings = Notification.Name("openSettings")
}

/// Поиск в шапке Mac. Своё поле, а не `.searchable`: системная строка поиска на Mac перехватывала фокус
/// у текстовых полей экрана — клик в поле задачи уводил курсор в поиск.
private struct MacSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button("Очистить", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 200)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Найденные задачи по всем спискам: сначала невыполненные.
struct SearchScreen: View {
    let query: String
    @Environment(\.database) private var database
    @State private var board = Board()

    var body: some View {
        let rows = board.search(query)
        TaskScroll {
            ForEach(rows) { row in
                TaskLink(id: row.id) {
                    TaskRowView(row: row, showList: board.list(row.task.listId)?.name, board: board)
                }
            }
        }
        .overlay { if rows.isEmpty { ContentUnavailableView.search(text: query) } }
        .navigationTitle("Поиск")
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .taskSelection(board: board)
        .observingBoard($board, in: database)
    }
}

/// На Mac — шапка без отдельной полосы заголовка, как у Напоминаний.
private struct UnifiedTitlebar: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.onAppear {
            // Без полосы заголовка: содержимое уходит под кнопки окна, и они встают в строку с левым разделом
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.toolbar = nil
            }
        }
        #else
        content
        #endif
    }
}
