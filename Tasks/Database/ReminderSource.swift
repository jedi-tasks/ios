import EventKit
import Foundation

/// Чтение Apple Reminders через EventKit. Только чтение — обратно ничего не пишем.
final class ReminderSource {
    private let store = EKEventStore()

    /// Повторов в v1 нет — эти списки не импортируем.
    static let skippedLists: Set<String> = ["Привычки", "Регулярные"]

    enum SourceError: LocalizedError {
        case denied
        var errorDescription: String? { "Нет доступа к Напоминаниям. Разреши его в Настройках iOS → Конфиденциальность → Напоминания." }
    }

    func requestAccess() async throws {
        guard try await store.requestFullAccessToReminders() else { throw SourceError.denied }
    }

    /// Активные напоминания всех списков (кроме пропускаемых) и выполненные за последние `completedDays` дней.
    func reminders(completedDays: Int = 30) async throws -> [ImportedReminder] {
        try await requestAccess()
        let calendars = store.calendars(for: .reminder).filter { !Self.skippedLists.contains($0.title) }
        guard !calendars.isEmpty else { return [] }
        let since = Calendar.current.date(byAdding: .day, value: -completedDays, to: Date())
        let active = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars))
        let done = await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: since, ending: nil, calendars: calendars))
        return (active + done).map { reminder in
            ImportedReminder(
                externalId: reminder.calendarItemIdentifier,
                listName: reminder.calendar.title,
                listColorHex: reminder.calendar.cgColor.flatMap(Self.hex),
                title: reminder.title ?? "",
                notes: reminder.notes ?? "",
                dueDay: reminder.dueDateComponents.flatMap(Self.dayKey),
                priority: reminder.priority,
                completedAt: reminder.isCompleted ? (reminder.completionDate ?? Date()) : nil
            )
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
    }

    private static func hex(_ color: CGColor) -> String? {
        guard let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              rgb.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(rgb[0] * 255), Int(rgb[1] * 255), Int(rgb[2] * 255))
    }

    private static func dayKey(_ components: DateComponents) -> String? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
