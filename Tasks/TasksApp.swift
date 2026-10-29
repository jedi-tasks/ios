import SwiftUI

@main
struct TasksApp: App {
    private let database: AppDatabase
    @State private var sync: SyncEngine

    init() {
        do {
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
    }
}

/// Без входа — экран входа. iPhone — таббар; iPad и Mac — боковая панель со списками, как в Напоминаниях.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncEngine.self) private var sync

    var body: some View {
        Group {
            if !sync.isSignedIn {
                LoginScreen()
            } else if sizeClass == .regular {
                SidebarRoot()
            } else {
                TabRoot()
            }
        }
        .onAppear { sync.start() }
        .onChange(of: scenePhase) { if scenePhase == .active { sync.schedule() } }
        .rejectedMutationsAlert(sync)
    }
}

struct TabRoot: View {
    @Environment(\.database) private var database
    @State private var board = Board()

    var body: some View {
        TabView {
            NavigationStack { TodayScreen() }
                .tabItem { Label("Сегодня", systemImage: "sun.max") }
            NavigationStack { PlannedScreen() }
                .tabItem { Label("В планах", systemImage: "calendar") }
            NavigationStack {
                if let inbox = board.inbox { ListScreen(listId: inbox.id) }
            }
            .tabItem { Label("Inbox", systemImage: "tray") }
            .badge(board.inbox.map { board.rows(in: $0.id, done: false).count } ?? 0)
            NavigationStack { ListsScreen() }
                .tabItem { Label("Списки", systemImage: "list.bullet") }
            NavigationStack { SettingsScreen() }
                .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
        .observingBoard($board, in: database)
    }
}
