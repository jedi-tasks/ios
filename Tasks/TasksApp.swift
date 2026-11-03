import SwiftUI

@main
struct TasksApp: App {
    private let database: AppDatabase
    @State private var sync: SyncEngine

    init() {
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demo") {
                let database = try AppDatabase.makeInMemory()
                try database.seedDemo()
                let sync = SyncEngine(database: database)
                sync.startDemo()
                self.database = database
                _sync = State(initialValue: sync)
                return
            }
            #endif
            let database = try AppDatabase.makeShared()
            self.database = database
            _sync = State(initialValue: SyncEngine(database: database))
        } catch {
            fatalError("Не удалось открыть базу данных: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.database, database)
                .environment(sync)
        }
        .commands {
            // На Mac настройки открываются из меню приложения, как везде: Cmd+,
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Без входа — экран входа. iPhone — таббар; iPad и Mac — боковая панель со списками, как в Напоминаниях.
struct RootView: View {
    @Environment(\.database) private var database
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncEngine.self) private var sync
    @State private var openedList: UUID?
    @State private var openedTask: OpenedTask?

    var body: some View {
        Group {
            if !sync.isSignedIn {
                LoginScreen()
            } else if sizeClass == .regular {
                SidebarRoot(openedList: $openedList)
            } else {
                TabRoot(openedList: $openedList)
            }
        }
        .onAppear { sync.start() }
        .onChange(of: scenePhase) { if scenePhase == .active { sync.schedule() } }
        .rejectedMutationsAlert(sync)
        .task { await WidgetExport.run(database: database) }
        .onOpenURL { url in
            guard sync.isSignedIn else { return }
            switch WidgetLink(url: url) {
            case .list(let id): openedList = id
            case .task(let id): openedTask = OpenedTask(id: id)
            case nil: break
            }
        }
        .sheet(item: $openedTask) { task in
            NavigationStack { TaskDetailScreen(taskId: task.id) }
        }
    }
}

/// Задача, открытая по ссылке из виджета.
private struct OpenedTask: Identifiable {
    let id: UUID
}

struct TabRoot: View {
    private enum Tab { case today, planned, inbox, lists, settings }

    @Environment(\.database) private var database
    /// Список, который просит открыть виджет.
    @Binding var openedList: UUID?
    @State private var board = Board()
    @State private var tab = Tab.today
    @State private var listsOpened: SidebarItem?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TodayScreen() }
                .tabItem { Label("Сегодня", systemImage: "sun.max") }
                .tag(Tab.today)
            NavigationStack { PlannedScreen() }
                .tabItem { Label("В планах", systemImage: "calendar") }
                .tag(Tab.planned)
            NavigationStack {
                if let inbox = board.inbox { ListScreen(listId: inbox.id) }
            }
            .tabItem { Label("Inbox", systemImage: "tray") }
            .badge(board.inbox.map { board.rows(in: $0.id, done: false).count } ?? 0)
            .tag(Tab.inbox)
            NavigationStack { ListsScreen(opened: $listsOpened) }
                .tabItem { Label("Списки", systemImage: "list.bullet") }
                .tag(Tab.lists)
            NavigationStack { SettingsScreen() }
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .observingBoard($board, in: database)
        .onChange(of: openedList, initial: true) {
            guard let id = openedList else { return }
            openedList = nil
            if id == board.inbox?.id {
                tab = .inbox
            } else {
                listsOpened = .list(id)
                tab = .lists
            }
        }
    }
}
