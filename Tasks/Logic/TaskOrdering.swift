import Foundation

enum TaskOrdering {
    /// Сортировка по режиму; пустые значения — в конце, при равенстве — ручной порядок.
    static func sorted(_ rows: [TaskRow], by mode: SortMode, blockedLast: Bool = false) -> [TaskRow] {
        rows.sorted { a, b in
            if blockedLast, a.isBlocked != b.isBlocked { return !a.isBlocked }
            if let order = compare(a, b, mode), order != .orderedSame { return order == .orderedAscending }
            return a.task.manualOrder < b.task.manualOrder
        }
    }

    private static func compare(_ a: TaskRow, _ b: TaskRow, _ mode: SortMode) -> ComparisonResult? {
        switch mode {
        case .manual: nil
        case .priority: optional(a.priority?.sortOrder, b.priority?.sortOrder)
        case .plannedDay: optional(a.task.plannedDay, b.task.plannedDay)
        case .deadline: optional(a.task.deadlineDay, b.task.deadlineDay)
        case .duration: optional(a.task.durationMinutes, b.task.durationMinutes)
        }
    }

    private static func optional<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?): a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        case (.some, nil): .orderedAscending
        case (nil, .some): .orderedDescending
        case (nil, nil): .orderedSame
        }
    }
}

enum BlockerGraph {
    /// Создаст ли блокер «`blocking` блокирует `task`» цикл: `task` уже (транзитивно) блокирует `blocking`.
    static func wouldCycle(task: UUID, blocking: UUID, edges: [(task: UUID, blocking: UUID)]) -> Bool {
        if task == blocking { return true }
        // Идём от `blocking` по его блокерам; если дойдём до `task` — цикл
        var stack = [blocking]
        var seen: Set<UUID> = []
        while let current = stack.popLast() {
            if current == task { return true }
            guard seen.insert(current).inserted else { continue }
            stack += edges.filter { $0.task == current }.map(\.blocking)
        }
        return false
    }
}
