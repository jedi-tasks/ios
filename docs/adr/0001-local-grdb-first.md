# 0001. Сначала локальное приложение на GRDB, связь с Reminders — потом через CalDAV

v1 — SwiftUI + GRDB локально, как Calories и HabitTracker. Модель сразу готова к синку:
`id: UUID`, `updatedAt`, `deletedAt` у каждой таблицы.

Связь с Apple Reminders не через EventKit в приложении, а позже через свой сервер (Go + gRPC по шаблону Coin),
который отдаёт задачи по CalDAV (VTODO): Reminders умеет подключать CalDAV-аккаунт.
Ограничение: VTODO в Reminders несёт только название, заметку, срок, приоритет high/medium/low и выполнение —
теги, разделы, блокеры и свои приоритеты останутся только в Tasks.
Мост через EventKit отвергнут: это работа, которую пришлось бы выбросить.
