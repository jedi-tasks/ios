import SwiftUI

/// Вход по почте и паролю. Регистрации в приложении нет.
struct LoginScreen: View {
    @Environment(SyncEngine.self) private var sync
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showsDeveloperTools = false
    @State private var titleTaps = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Почта", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Войти")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                } footer: {
                    // Пять касаний — инструменты разработчика (выбор сервера)
                    Text("Сервер: \(ServerEndpoint.current.title)")
                        .onTapGesture {
                            titleTaps += 1
                            if titleTaps >= 5 { titleTaps = 0; showsDeveloperTools = true }
                        }
                }
            }
            .navigationTitle("Задачи")
            .sheet(isPresented: $showsDeveloperTools) {
                NavigationStack { DeveloperToolsScreen() }
            }
        }
    }

    private func signIn() {
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await sync.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
