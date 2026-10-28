import Foundation

/// Оценка длительности одной корзиной: фильтр «до N» и значение, которое ставится при перетаскивании.
enum DurationBucket: Int, CaseIterable, Hashable, Sendable {
    case m15 = 15, m30 = 30, h1 = 60, h2 = 120, more = 240

    var title: String {
        switch self {
        case .m15: "До 15 мин"
        case .m30: "До 30 мин"
        case .h1: "До 1 ч"
        case .h2: "До 2 ч"
        case .more: "Больше 2 ч"
        }
    }

    var icon: String {
        switch self {
        case .m15: "hare"
        case .m30: "clock"
        case .h1: "hourglass.bottomhalf.filled"
        case .h2: "hourglass"
        case .more: "tortoise"
        }
    }

    /// Длительность, которую получает задача, брошенная на корзину.
    var minutes: Int { rawValue }

    static func of(_ minutes: Int) -> DurationBucket {
        allCases.first { minutes <= $0.rawValue && $0 != .more } ?? .more
    }
}

/// Умная подборка задач под списками: по приоритету, длительности или тегу.
enum TaskFilter: Hashable, Sendable {
    /// `nil` — «Не разобрано».
    case priority(UUID?)
    case duration(DurationBucket)
    case tag(UUID)
}

extension Board {
    /// Невыполненные задачи подборки, по приоритету.
    func rows(matching filter: TaskFilter) -> [TaskRow] {
        let matching = rows.filter { row in
            guard !row.isDone else { return false }
            switch filter {
            case .priority(let id): return row.task.priorityId == id
            case .duration(let bucket): return row.task.durationMinutes.map { DurationBucket.of($0) == bucket } ?? false
            case .tag(let id): return row.tags.contains { $0.id == id }
            }
        }
        return TaskOrdering.sorted(matching, by: .priority)
    }

    func title(of filter: TaskFilter) -> String {
        switch filter {
        case .priority(let id): priorities.first { $0.id == id }?.name ?? "Не разобрано"
        case .duration(let bucket): bucket.title
        case .tag(let id): "#" + (tags.first { $0.id == id }?.name ?? "")
        }
    }
}
