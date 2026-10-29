import SwiftUI

/// Журнал запросов к серверу: метод, время, статус; по нажатию — тексты запроса и ответа.
struct APILogScreen: View {
    private var log = APILog.shared
    @State private var onlyFailures = false

    var body: some View {
        List {
            Toggle("Только ошибки", isOn: $onlyFailures)
            ForEach(log.entries.filter { !onlyFailures || $0.isFailure }) { entry in
                NavigationLink {
                    APILogEntryScreen(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: entry.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(entry.isFailure ? .red : .green)
                            Text(entry.method).font(.footnote.monospaced())
                            Spacer()
                            Text(entry.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        if let error = entry.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    }
                }
            }
        }
        .navigationTitle("Запросы: \(log.entries.count)")
        .toolbar { Button("Очистить", role: .destructive) { log.clear() } }
    }
}

/// Подробности одного запроса.
struct APILogEntryScreen: View {
    let entry: APILog.Entry

    var body: some View {
        List {
            if let error = entry.error {
                Section("Ошибка") { Text(error).font(.footnote.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Запрос") { Text(entry.request).font(.footnote.monospaced()).textSelection(.enabled) }
            if let response = entry.response {
                Section("Ответ") { Text(response).font(.footnote.monospaced()).textSelection(.enabled) }
            }
        }
        .navigationTitle(entry.method)
        .toolbar {
            ShareLink(item: "\(entry.method)\n\n\(entry.request)\n\n\(entry.response ?? entry.error ?? "")")
        }
    }
}
