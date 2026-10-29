import Foundation
import GRPCCore
import OSLog

private let logger = Logger(subsystem: "tasks", category: "Sync")

/// Офлайн-синк, как в Coin: очередь правок уходит на сервер по порядку, затем `Sync`/`ConfirmSync`
/// забирают чужие изменения; `SubscribeToSync` будит синк, пока приложение открыто.
/// Плюс вход/выход: аккаунт обязателен, данные пользователя — с сервера.
@MainActor
@Observable
final class SyncEngine {
    let database: AppDatabase
    private let api = APIClient.shared

    private(set) var isSignedIn = TokenStore.refreshToken != nil
    private(set) var email = TokenStore.email
    private(set) var isSyncing = false
    private(set) var queueCount = 0
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncSummary: String?
    private(set) var lastError: String?
    /// Правки, которые сервер отклонил: показываются пользователю и убираются из очереди.
    var rejected: [String] = []

    private var rerun = false
    private var needsFullSync = false
    private var loops: [Task<Void, Never>] = []

    init(database: AppDatabase) {
        self.database = database
        let onLogout: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in await self?.signOut(remote: false) }
        }
        Task { await APIClient.shared.setLogoutHandler(onLogout) }
    }

    // MARK: - Вход и выход

    /// Вход стирает локальную базу и скачивает данные с сервера полным синком.
    func signIn(email: String, password: String) async throws {
        try await api.signIn(email: email, password: password)
        try database.wipe()
        self.email = email
        isSignedIn = true
        start()
        await run()
        if let lastError, (try? database.checkpoint()) == 0 { throw APIError(message: lastError) }
    }

    func signOut(remote: Bool = true) async {
        stop()
        if remote { await api.signOut() }
        TokenStore.clear()
        try? database.wipe()
        isSignedIn = false
        email = nil
        lastSyncSummary = nil
        lastError = nil
    }

    func changeServer(_ endpoint: ServerEndpoint) async {
        await signOut()
        ServerEndpoint.current = endpoint
        await api.reset()
    }

    // MARK: - Циклы

    /// Запуск при старте приложения и после входа: очередь, синк, подписка, повтор по таймеру.
    func start() {
        guard isSignedIn, loops.isEmpty else { return }
        try? database.resetInFlight()
        loops.append(Task { [weak self] in
            guard let self else { return }
            do {
                for try await count in database.observeQueueCount() {
                    let grew = count > queueCount
                    queueCount = count
                    if grew { schedule() }
                }
            } catch {}
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if queueCount > 0 || lastError != nil { schedule() }
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let api = self?.api else { return }
                do {
                    try await api.subscribe { [weak self] in await self?.run() }
                } catch {
                    if !Task.isCancelled { logger.warning("SubscribeToSync: \(String(describing: error), privacy: .public)") }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        })
        schedule()
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops = []
    }

    func schedule() {
        Task { await run() }
    }

    /// Полная пересинхронизация с нуля (инструменты разработчика).
    func fullSync() async {
        needsFullSync = true
        await run()
    }

    /// Один проход: очередь → синк. Повторный вызов во время прохода — ещё один проход после.
    func run() async {
        guard isSignedIn else { return }
        if isSyncing { rerun = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerun = false
            do {
                try await pushQueue()
                try await pull(full: needsFullSync)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                logger.warning("Синк не удался: \(String(describing: error), privacy: .public)")
            }
        } while rerun && isSignedIn
    }

    // MARK: - Отправка очереди

    private func pushQueue() async throws {
        var syncedForGate = false
        while isSignedIn, let row = try database.nextQueued(), let id = row.id {
            guard let mutation = row.mutation else {
                try database.removeQueued(id)
                continue
            }
            try database.markInFlight(id, true)
            do {
                try await api.send(mutation)
                try database.removeQueued(id)
                syncedForGate = false
            } catch let error as APIError where error.category == .needToSync && !syncedForGate {
                // Сервер принимает правки только от синхронизированного устройства: синк и повтор
                try database.markInFlight(id, false)
                syncedForGate = true
                try await pull(full: false)
            } catch let error as APIError where error.category == .other {
                // Сервер отверг правку (проверка целостности и т.п.) — показать и выбросить;
                // полный синк вернёт серверное состояние
                logger.warning("Отклонено \(mutation.title, privacy: .public): \(error.message, privacy: .public)")
                rejected.append(error.message)
                if mutation.isCreate { try database.dropRejectedCreate(mutation) }
                try database.removeQueued(id)
                needsFullSync = true
            } catch {
                try database.markInFlight(id, false, error: Self.describe(error))
                throw error
            }
        }
    }

    // MARK: - Получение изменений

    private func pull(full: Bool) async throws {
        let since = full ? 0 : try database.checkpoint()
        let changes = try await api.sync(since: since)
        if full { needsFullSync = false }
        guard let token = changes.syncToken else {
            lastSyncAt = Date()
            if !full { lastSyncSummary = "Изменений нет" }
            return
        }
        try database.apply(changes, full: full || since == 0)
        if let capacity = changes.dailyCapacityMinutes {
            UserDefaults.standard.set(capacity, forKey: "dailyCapacityMinutes")
        }
        do {
            try await api.confirmSync(token: token)
            try database.setCheckpoint(changes.checkpoint)
        } catch let error as APIError where error.category == .needToSync {
            // Пока применяли, на сервере появились новые изменения — следующий проход переспросит
            rerun = true
        }
        lastSyncAt = Date()
        lastSyncSummary = changes.summary
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? RPCError { return "\(error.code): \(error.message)" }
        return error.localizedDescription
    }
}

extension APIClient {
    func setLogoutHandler(_ handler: @escaping @Sendable () -> Void) {
        onLogout = handler
    }
}
