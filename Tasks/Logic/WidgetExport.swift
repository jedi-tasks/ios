import Foundation
import OSLog
import WidgetKit

private let logger = Logger(subsystem: "tasks", category: "Widget")

extension WidgetSnapshot {
    init(board: Board) {
        lists = board.lists.map { list in
            let rows = board.rows(in: list.id, done: false)
            return List(
                id: list.id,
                name: list.name,
                colorHex: list.colorHex,
                icon: list.icon,
                isInbox: list.isInbox,
                sortMode: list.sortMode.rawValue,
                tasks: rows.map { row in
                    Task(
                        id: row.id,
                        title: row.task.title,
                        priorityMarks: row.priority?.marks,
                        priorityColorHex: row.priority?.colorHex,
                        plannedDay: row.task.plannedDay,
                        deadlineDay: row.task.deadlineDay,
                        isBlocked: row.isBlocked
                    )
                },
                orders: Dictionary(uniqueKeysWithValues: SortMode.allCases.map { mode in
                    (mode.rawValue, TaskOrdering.sorted(rows, by: mode).map(\.id))
                })
            )
        }
    }
}

enum WidgetExport {
    /// Пока приложение живо, держит снимок виджета актуальным. После выхода база пуста — снимок тоже.
    static func run(database: AppDatabase) async {
        var last = WidgetSnapshot.load()
        do {
            for try await board in database.observe(AppDatabase.fetchBoard) {
                let snapshot = WidgetSnapshot(board: board)
                guard snapshot != last else { continue }
                try snapshot.save()
                last = snapshot
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
            }
        } catch {
            logger.error("Не удалось обновить снимок виджета: \(error)")
        }
    }
}
