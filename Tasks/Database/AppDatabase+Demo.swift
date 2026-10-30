#if DEBUG
import Foundation

extension AppDatabase {
    /// Задачи для демо-режима (`-demo`): на сегодня, с заметкой, блокером и без срока.
    func seedDemo() throws {
        let today = DayKey.today
        // Inbox обычно приходит с сервера
        try saveList(TaskList(name: "Inbox", isInbox: true, icon: "tray.fill"))
        let titles = ["Взвесить всю посуду", "Сходить на тренировку", "Разобрать замечания по дизайну",
                      "Ответить на письмо банка", "Купить кабель micro-USB", "Позвонить маме"]
        var tasks: [TaskItem] = []
        for title in titles { tasks.append(try addTask(title: title, listId: nil, plannedDay: today)) }
        var noted = tasks[2]
        noted.notes = "Первый шаг: выписать замечания списком.\nПотом пройтись по каждому."
        noted.durationMinutes = 60
        _ = try saveTask(noted)
        try addBlocker(task: tasks[3].id, reason: "Ждём ответа поддержки")
        try addBlocker(task: tasks[4].id, blockingTask: tasks[5].id)
        for title in ["Выставить паяльник на продажу", "Заштопать рашгард", "Достать данные с диска"] {
            _ = try addTask(title: title, listId: nil)
        }
    }
}
#endif
