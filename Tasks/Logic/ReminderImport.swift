import Foundation

/// Напоминание, прочитанное из Apple Reminders, — вход импорта.
struct ImportedReminder: Sendable {
    var externalId: String
    var listName: String
    var listColorHex: String? = nil
    var title: String
    var notes: String
    var dueDay: String?
    /// Приоритет EventKit: 0 — нет, 1–4 — высокий, 5 — средний, 6–9 — низкий.
    var priority: Int
    var completedAt: Date?
}

struct ImportResult: Sendable, Equatable {
    var added = 0
    var skipped = 0
}

/// Служебные строки заметок системы «Путь джедая».
struct ReminderNote: Equatable {
    var section: String?
    var blockerReason: String?
    var blockerSinceDay: String?
    var durationMinutes: Int?
    var body: String

    /// `Раздел: X` и `Заблокировано: <чем> с <даты>` уходят в поля и убираются из текста.
    /// Оценки `~30 мин`, `~1,5 ч` суммируются в длительность (до набора её округляет импорт); текст остаётся.
    static func parse(_ notes: String, year: Int = Calendar.current.component(.year, from: Date())) -> ReminderNote {
        var result = ReminderNote(body: "")
        var bodyLines: [Substring] = []
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if result.section == nil, let value = trimmed.value(after: "Раздел:") {
                result.section = value
            } else if result.blockerReason == nil, let value = trimmed.value(after: "Заблокировано:") {
                (result.blockerReason, result.blockerSinceDay) = splitSince(value, year: year)
            } else {
                bodyLines.append(line)
            }
        }
        result.body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result.durationMinutes = duration(in: notes)
        return result
    }

    /// «ответа от Пети с 2026-10-20» / «… с 20.10» → причина и день.
    private static func splitSince(_ value: String, year: Int) -> (String, String?) {
        guard let range = value.range(of: " с ", options: .backwards) else { return (value, nil) }
        var date = value[range.upperBound...].trimmingCharacters(in: .whitespaces)
        while let last = date.last, !last.isNumber { date.removeLast() }
        let reason = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        if DayKey.date(from: date) != nil, date.count == 10 { return (reason, date) }
        let parts = date.split(separator: ".").compactMap { Int($0) }
        if parts.count >= 2, (1...31).contains(parts[0]), (1...12).contains(parts[1]) {
            let y = parts.count > 2 ? (parts[2] < 100 ? 2000 + parts[2] : parts[2]) : year
            return (reason, String(format: "%04d-%02d-%02d", y, parts[1], parts[0]))
        }
        return (value, nil)
    }

    private static let durationPattern = try! Regex(#"~\s*(\d+(?:[.,]\d+)?)\s*(мин|ч)"#, as: (Substring, Substring, Substring).self)

    static func duration(in text: String) -> Int? {
        let minutes = text.matches(of: durationPattern).compactMap { match -> Double? in
            guard let number = Double(match.1.replacingOccurrences(of: ",", with: ".")) else { return nil }
            return match.2 == "ч" ? number * 60 : number
        }
        return minutes.isEmpty ? nil : Int(minutes.reduce(0, +).rounded())
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let value = dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
