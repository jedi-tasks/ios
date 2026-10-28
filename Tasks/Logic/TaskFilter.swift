import Foundation

/// Набор длительностей по умолчанию (теги-оценки «Пути джедая»). Сам набор живёт в справочнике `DurationOption`
/// и меняется в Настройках; это — начальное заполнение и миграция v6.
/// В задаче хранится `durationMinutes`; «непрогнозируемо долго» — `-1`.
enum TaskDuration: Int, CaseIterable, Hashable, Sendable {
    case m5 = 5, m15 = 15, m30 = 30, h1 = 60, h2 = 120, h5 = 300, unpredictable = -1

    var title: String {
        switch self {
        case .m5: "5 мин"
        case .m15: "15 мин"
        case .m30: "30 мин"
        case .h1: "1 ч"
        case .h2: "2 ч"
        case .h5: "5 ч"
        case .unpredictable: "Непрогнозируемо долго"
        }
    }

    var minutes: Int { rawValue }

    /// Ближайшее значение набора; при равенстве — большее (лучше переоценить).
    static func of(_ minutes: Int) -> TaskDuration {
        if minutes < 0 { return .unpredictable }
        return allCases.filter { $0 != .unpredictable }
            .min { a, b in
                let da = abs(a.rawValue - minutes), db = abs(b.rawValue - minutes)
                return da == db ? a.rawValue > b.rawValue : da < db
            }!
    }
}

/// Умная подборка задач под списками: по приоритету, длительности или тегу.
enum TaskFilter: Hashable, Sendable {
    /// `nil` — «Не разобрано».
    case priority(UUID?)
    /// Минуты значения из справочника длительностей.
    case duration(Int)
    case tag(UUID)
}

extension Board {
    /// Невыполненные задачи подборки, по приоритету.
    func rows(matching filter: TaskFilter) -> [TaskRow] {
        let matching = rows.filter { row in
            guard !row.isDone else { return false }
            switch filter {
            case .priority(let id): return row.task.priorityId == id
            case .duration(let minutes): return row.task.durationMinutes == minutes
            case .tag(let id): return row.tags.contains { $0.id == id }
            }
        }
        return TaskOrdering.sorted(matching, by: .priority)
    }

    func title(of filter: TaskFilter) -> String {
        switch filter {
        case .priority(let id): priorities.first { $0.id == id }?.name ?? "Не разобрано"
        case .duration(let minutes): durations.first { $0.minutes == minutes }?.title ?? Workload.format(minutes)
        case .tag(let id): "#" + (tags.first { $0.id == id }?.name ?? "")
        }
    }
}

enum DurationSnap {
    /// Ближайшее значение набора; при равенстве — большее (лучше переоценить). «Непрогнозируемо» — только само к себе.
    static func nearest(_ minutes: Int, in values: [Int]) -> Int? {
        if minutes < 0 { return values.first { $0 < 0 } }
        return values.filter { $0 >= 0 }.min { a, b in
            let da = abs(a - minutes), db = abs(b - minutes)
            return da == db ? a > b : da < db
        }
    }
}
