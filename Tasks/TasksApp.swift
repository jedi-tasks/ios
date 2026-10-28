import SwiftUI

@main
struct TasksApp: App {
    private let database: AppDatabase

    init() {
        do {
            database = try AppDatabase.makeShared()
        } catch {
            fatalError("Не удалось открыть базу данных: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(\.database, database)
        }
    }
}

/// iPhone — таббар; iPad и Mac — боковая панель со списками, как в Напоминаниях.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular { SidebarRoot() } else { TabRoot() }
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
