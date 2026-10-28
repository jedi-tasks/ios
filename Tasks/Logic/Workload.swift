import Foundation

/// Сумма оценок длительности для набора задач.
struct Workload: Equatable, Sendable {
    var minutes = 0
    /// Задачи без оценки — в сумму не входят, но о них стоит знать.
    var unestimated = 0
    /// «Непрогнозируемо долго» — в сумму не входят.
    var unpredictable = 0
    var count = 0

    init(_ rows: [TaskRow]) {
        for row in rows {
            count += 1
            switch row.task.durationMinutes {
            case nil: unestimated += 1
            case let value? where value < 0: unpredictable += 1
            case let value?: minutes += value
            }
        }
    }

    /// «≈ 3 ч 15 мин · 2 без оценки»; пусто, если задач нет.
    var summary: String {
        guard count > 0 else { return "" }
        var parts: [String] = []
        if minutes > 0 { parts.append("≈ " + Self.format(minutes)) }
        if unpredictable > 0 { parts.append("\(unpredictable) непрогнозируемо долго") }
        if unestimated > 0 { parts.append("\(unestimated) без оценки") }
        return parts.joined(separator: " · ")
    }

    static func format(_ minutes: Int) -> String {
        if minutes < 0 { return "Непрогнозируемо долго" }
        if minutes < 60 { return "\(minutes) мин" }
        return minutes % 60 == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(minutes % 60) мин"
    }
}

extension Board {
    /// План по дням: каждый из `days` дней начиная с сегодня, включая пустые.
    func planDays(from today: String, days: Int = 14) -> [(day: String, rows: [TaskRow])] {
        guard let start = DayKey.date(from: today) else { return [] }
        let open = rows.filter { !$0.isDone }
        return (0..<days).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: start) else { return nil }
            let day = DayKey.string(from: date)
            let dayRows = open.filter { ($0.task.plannedDay ?? $0.task.deadlineDay) == day }
            return (day, TaskOrdering.sorted(dayRows, by: .priority))
        }
    }

    /// Невыполненные, чей день (срок, иначе дедлайн) уже прошёл.
    func overdue(_ today: String) -> [TaskRow] {
        TaskOrdering.sorted(rows.filter { row in
            guard !row.isDone, let day = row.task.plannedDay ?? row.task.deadlineDay else { return false }
            return day < today
        }, by: .priority)
    }
}
