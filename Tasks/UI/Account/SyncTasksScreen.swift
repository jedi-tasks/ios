import SwiftUI

/// Раздел разработчика: очередь правок на отправку и история их отправки.
/// Правки уходят строго по порядку записи; первая в очереди блокирует остальные, пока не уйдёт.
struct SyncTasksScreen: View {
    @Environment(SyncEngine.self) private var sync
    @State private var queue: [QueuedMutation] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Состояние", value: sync.isSyncing ? "идёт синк" : "ожидание")
                if let error = sync.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("Отправить сейчас") { sync.schedule() }
            }
            Section {
                if queue.isEmpty { Text("Пусто").foregroundStyle(.secondary) }
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, row in
                    QueueRow(index: index, row: row)
                }
            } header: {
                Text("Очередь: \(queue.count)")
            } footer: {
                Text("Отправляются по порядку сверху вниз. Порядок задаёт момент записи правки; дочерние правки (снятие тега, блокера) записываются раньше удаления родителя.")
            }
            Section {
                if sync.history.isEmpty { Text("Пока ничего не отправлялось").foregroundStyle(.secondary) }
                ForEach(sync.history) { entry in
                    HistoryRow(entry: entry)
                }
            } header: {
                Text("История: \(sync.history.count)")
            }
        }
        .navigationTitle("Синк-задачи")
        .toolbar { Button("Очистить историю") { sync.clearHistory() } }
        .onAppear(perform: reload)
        .onChange(of: sync.queueCount) { reload() }
        .onChange(of: sync.history.count) { reload() }
        .onChange(of: sync.isSyncing) { reload() }
    }

    private func reload() {
        queue = (try? sync.database.queue()) ?? []
    }
}

private struct QueueRow: View {
    let index: Int
    let row: QueuedMutation

    private var status: (String, Color) {
        if row.inFlight { return ("отправляется", .blue) }
        if row.lastError != nil { return ("ошибка, попыток \(row.tryCount)", .red) }
        return (index == 0 ? "следующая" : "ждёт", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#\(row.id ?? 0)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(row.mutation?.title ?? "не читается").font(.footnote.monospaced())
            }
            HStack {
                Text(status.0).foregroundStyle(status.1)
                Spacer()
                Text(row.createdAt.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
            }
            .font(.caption)
            if let error = row.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct HistoryRow: View {
    let entry: SyncHistoryEntry

    private var color: Color {
        switch entry.status {
        case .sent: .green
        case .needToSync: .orange
        case .rejected, .failed: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.mutation.title).font(.footnote.monospaced())
            HStack {
                Text(entry.status.title).foregroundStyle(color)
                Spacer()
                Text("\(Int(entry.duration * 1000)) мс · \(entry.date.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
