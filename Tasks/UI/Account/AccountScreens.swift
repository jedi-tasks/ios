import SwiftUI

/// Секция аккаунта в настройках: почта, состояние синка, смена пароля, выход.
struct AccountSection: View {
    @Environment(SyncEngine.self) private var sync
    @State private var confirmsSignOut = false
    @State private var showsDeveloperTools = false
    @State private var versionTaps = 0

    var body: some View {
        Section {
            LabeledContent("Аккаунт", value: sync.email ?? "—")
            LabeledContent("Синхронизация") {
                if sync.isSyncing {
                    ProgressView()
                } else if let error = sync.lastError {
                    Text(error).foregroundStyle(.red).lineLimit(2)
                } else if sync.queueCount > 0 {
                    Text("Не отправлено: \(sync.queueCount)")
                } else {
                    Text("Всё отправлено")
                }
            }
            NavigationLink("Сменить пароль") { ChangePasswordScreen() }
            Button("Выйти", role: .destructive) { confirmsSignOut = true }
        } header: {
            Text("Аккаунт")
        } footer: {
            // Пять касаний — инструменты разработчика
            Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(ServerEndpoint.current.title)")
                .onTapGesture {
                    versionTaps += 1
                    if versionTaps >= 5 { versionTaps = 0; showsDeveloperTools = true }
                }
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await sync.signOut() } }
        } message: {
            Text(sync.queueCount > 0
                 ? "Не отправлено правок: \(sync.queueCount). Они пропадут вместе с локальными данными."
                 : "Локальные данные будут стёрты, на сервере всё останется.")
        }
        .sheet(isPresented: $showsDeveloperTools) {
            NavigationStack { DeveloperToolsScreen() }
        }
    }
}

/// Смена пароля — сразу на сервере, не через очередь.
struct ChangePasswordScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        Form {
            Section {
                SecureField("Текущий пароль", text: $old).textContentType(.password)
                SecureField("Новый пароль", text: $new).textContentType(.newPassword)
                SecureField("Новый пароль ещё раз", text: $repeated).textContentType(.newPassword)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
                else if !repeated.isEmpty, new != repeated { Text("Пароли не совпадают").foregroundStyle(.red) }
            }
            Button {
                save()
            } label: {
                HStack { Text("Сменить пароль"); if busy { Spacer(); ProgressView() } }
            }
            .disabled(busy || old.isEmpty || new.isEmpty || new != repeated)
        }
        .navigationTitle("Смена пароля")
        .alert("Пароль изменён", isPresented: $done) {
            Button("OK") { dismiss() }
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.changePassword(old: old, new: new)
                done = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Скрытые инструменты разработчика: адрес сервера, очередь синка, ручной синк.
struct DeveloperToolsScreen: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var host = ServerEndpoint.current.host
    @State private var port = String(ServerEndpoint.current.port)
    @State private var tls = ServerEndpoint.current.tls
    @State private var queue: [QueuedMutation] = []
    @State private var checkpoint: UInt32 = 0

    var body: some View {
        Form {
            Section {
                ForEach(ServerEndpoint.presets, id: \.name) { preset in
                    Button {
                        host = preset.endpoint.host
                        port = String(preset.endpoint.port)
                        tls = preset.endpoint.tls
                    } label: {
                        LabeledContent(preset.name, value: preset.endpoint.title)
                    }
                }
                TextField("Хост", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Порт", text: $port).keyboardType(.numberPad)
                Toggle("TLS", isOn: $tls)
                Button("Применить") {
                    let endpoint = ServerEndpoint(host: host, port: Int(port) ?? 443, tls: tls)
                    Task { await sync.changeServer(endpoint); dismiss() }
                }
                .disabled(ServerEndpoint(host: host, port: Int(port) ?? 443, tls: tls) == ServerEndpoint.current)
            } header: {
                Text("Сервер: \(ServerEndpoint.current.title)")
            } footer: {
                Text("Смена сервера выходит из аккаунта и стирает локальные данные. По умолчанию — \(ServerEndpoint.buildDefault.title).")
            }
            if sync.isSignedIn {
                Section("Синк") {
                    LabeledContent("Чекпоинт", value: String(checkpoint))
                    LabeledContent("Последний", value: sync.lastSyncAt?.formatted(date: .omitted, time: .standard) ?? "—")
                    if let summary = sync.lastSyncSummary { Text(summary).font(.footnote) }
                    if let error = sync.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                    Button("Синхронизировать") { Task { await sync.run(); reload() } }
                    Button("Полный синк с нуля") { Task { await sync.fullSync(); reload() } }
                }
                Section("Очередь: \(queue.count)") {
                    ForEach(queue) { row in
                        VStack(alignment: .leading) {
                            Text(row.mutation?.title ?? "?").font(.footnote.monospaced())
                            if let error = row.lastError {
                                Text("попыток \(row.tryCount): \(error)").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Разработчику")
        .toolbar { Button("Готово") { dismiss() } }
        .onAppear(perform: reload)
        .onChange(of: sync.queueCount) { reload() }
    }

    private func reload() {
        queue = (try? sync.database.queue()) ?? []
        checkpoint = (try? sync.database.checkpoint()) ?? 0
    }
}

extension View {
    /// Алерт об отклонённых сервером правках.
    func rejectedMutationsAlert(_ sync: SyncEngine) -> some View {
        alert("Сервер не принял изменения", isPresented: Binding(
            get: { !sync.rejected.isEmpty },
            set: { if !$0 { sync.rejected = [] } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(Array(Set(sync.rejected)).joined(separator: "\n") + "\n\nДанные возвращены к серверным.")
        }
    }
}
