import SwiftUI

/// Справочник приоритетов: порядок сверху вниз — от важного к неважному.
struct SettingsScreen: View {
    @Environment(\.database) private var database
    @State private var board = Board()
    @State private var errors = ErrorAlert()
    @State private var importing = false
    @AppStorage("dailyCapacityMinutes") private var capacity = 360
    @State private var importResult: ImportResult?

    var body: some View {
        List {
            Section {
                ForEach(board.priorities) { priority in
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: priority.colorHex) },
                            set: { color in update(priority) { $0.colorHex = color.hex } }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        TextField("!", text: Binding(
                            get: { priority.marks },
                            set: { marks in update(priority) { $0.marks = marks } }
                        ))
                        .bold()
                        .foregroundStyle(Color(hex: priority.colorHex))
                        .frame(width: 44)
                        TextField("Название", text: Binding(
                            get: { priority.name },
                            set: { name in update(priority) { $0.name = name } }
                        ))
                    }
                }
                .onMove { from, to in
                    var ids = board.priorities.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    errors.run { try database.reorder(table: "priority", ids: ids) }
                }
                .onDelete { offsets in
                    errors.run { for index in offsets { try database.deletePriority(board.priorities[index].id) } }
                }
                Button("Добавить уровень", systemImage: "plus") {
                    errors.run { try database.savePriority(Priority(name: "Новый", colorHex: "#8E8E93")) }
                }
            } header: {
                Text("Приоритеты")
            } footer: {
                Text("Сверху — важнее. Знаки (например «!!!») показываются перед названием задачи. Задачи удалённого уровня становятся «не разобрано».")
            }
            Section {
                ForEach(board.durations) { option in
                    HStack {
                        TextField("Название", text: Binding(
                            get: { option.title },
                            set: { title in updateDuration(option) { $0.title = title } }
                        ))
                        if option.isUnpredictable {
                            Text("вне суммы").foregroundStyle(.secondary)
                        } else {
                            Stepper(value: Binding(
                                get: { option.minutes },
                                set: { minutes in updateDuration(option) { $0.minutes = minutes } }
                            ), in: 5...(24 * 60), step: 5) {
                                Text(Workload.format(option.minutes)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .fixedSize()
                        }
                    }
                }
                .onDelete { offsets in
                    errors.run { for index in offsets { try database.deleteDuration(board.durations[index].id) } }
                }
                Button("Добавить длительность", systemImage: "plus") {
                    errors.run { try database.saveDuration(DurationOption(title: "45 мин", minutes: 45)) }
                }
            } header: {
                Text("Длительности")
            } footer: {
                Text("Набор оценок для задач. Поменяли минуты — задачи с этим значением получат новое; удалили — перейдут к ближайшему.")
            }
            Section {
                Stepper(value: $capacity, in: 60...(16 * 60), step: 30) {
                    LabeledContent("Лимит на день", value: Workload.format(capacity))
                }
            } footer: {
                Text("С ним сравнивается загрузка дней в «В планах»: сумма оценок задач дня.")
            }
            Section {
                Button {
                    Task { await importReminders() }
                } label: {
                    HStack {
                        Label("Импорт из Напоминаний", systemImage: "square.and.arrow.down")
                        if importing { Spacer(); ProgressView() }
                    }
                }
                .disabled(importing)
            } footer: {
                Text("Активные задачи и выполненные за 30 дней, кроме «Привычки» и «Регулярные». Повторный импорт добавляет только новое.")
            }
        }
        .navigationTitle("Настройки")
        .toolbar { EditButton() }
        .observingBoard($board, in: database)
        .errorAlert(errors)
        .alert("Импорт завершён", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Добавлено: \(importResult?.added ?? 0), пропущено: \(importResult?.skipped ?? 0)")
        }
    }

    private func importReminders() async {
        importing = true
        defer { importing = false }
        do {
            let reminders = try await ReminderSource().reminders()
            importResult = try database.importReminders(reminders)
        } catch {
            errors.message = error.localizedDescription
        }
    }

    private func updateDuration(_ option: DurationOption, _ change: (inout DurationOption) -> Void) {
        var updated = option
        change(&updated)
        errors.run { try database.saveDuration(updated) }
    }

    private func update(_ priority: Priority, _ change: (inout Priority) -> Void) {
        var updated = priority
        change(&updated)
        errors.run { try database.savePriority(updated) }
    }
}
