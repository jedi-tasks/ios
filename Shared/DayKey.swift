import Foundation

/// Ключ дня `yyyy-MM-dd` в текущем часовом поясе.
enum DayKey {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static var today: String { string(from: Date()) }

    /// «28 окт» для отображения.
    static func short(_ key: String) -> String {
        guard let date = date(from: key) else { return key }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
