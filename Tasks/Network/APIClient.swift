import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import OSLog
import ProtoDefinitions
import SwiftProtobuf
import UIKit

private let logger = Logger(subsystem: "tasks", category: "gRPC")

/// Ошибка сервера (поле `error` ответа) или клиента.
struct APIError: LocalizedError, Sendable {
    enum Category: Sendable { case `internal`, needToLogout, needToSync, needToRefreshToken, other }
    var category: Category = .other
    var message: String
    var systemMessage: String = ""

    var errorDescription: String? { message }

    init(message: String, category: Category = .other, systemMessage: String = "") {
        self.message = message
        self.category = category
        self.systemMessage = systemMessage
    }

    init(_ proto: Error_Error) {
        switch proto.category {
        case .internal: category = .internal
        case .needToLogout: category = .needToLogout
        case .needToSync: category = .needToSync
        case .needToRefreshToken: category = .needToRefreshToken
        default: category = .other
        }
        message = proto.message.isEmpty ? "Ошибка сервера" : proto.message
        systemMessage = proto.systemMessage
    }
}

protocol HasAccessToken { var accessToken: String { get set } }
protocol HasErrorField {
    var hasError: Bool { get }
    var error: Error_Error { get }
}

/// Сетевой слой: один gRPC-клиент на адрес сервера, подстановка и обновление токенов,
/// конвертация правок очереди в запросы.
actor APIClient {
    static let shared = APIClient()

    private var endpoint: ServerEndpoint?
    private var client: GRPCClient<HTTP2ClientTransport.Posix>?
    private var runTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?

    /// Срабатывает, когда сервер окончательно отверг сессию.
    nonisolated(unsafe) var onLogout: (@Sendable () -> Void)?

    private func grpc() throws -> GRPCClient<HTTP2ClientTransport.Posix> {
        let target = ServerEndpoint.current
        if let client, endpoint == target { return client }
        client?.beginGracefulShutdown()
        runTask?.cancel()
        logger.info("Подключение к \(target.title, privacy: .public)")
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: target.host, port: target.port),
            transportSecurity: target.tls ? .tls : .plaintext
        )
        let client = GRPCClient(transport: transport)
        runTask = Task { try? await client.runConnections() }
        self.client = client
        endpoint = target
        return client
    }

    /// Сбросить соединение (после смены адреса сервера).
    func reset() {
        client?.beginGracefulShutdown()
        runTask?.cancel()
        client = nil
        endpoint = nil
    }

    // MARK: - Вызовы

    private func unwrap<Res: HasErrorField>(_ response: Res) throws -> Res {
        if response.hasError { throw APIError(response.error) }
        return response
    }

    /// Выполняет запрос и пишет его в журнал вместе с ответом или ошибкой.
    private func logged<Req: Message, Res: HasErrorField & Message>(
        _ name: String, _ request: Req, _ perform: () async throws -> Res
    ) async throws -> Res {
        let started = ContinuousClock.now
        let sent = request
        do {
            let response = try await perform()
            APILog.record(name, request: request, started: started, response: response,
                          error: response.hasError ? "\(response.error.category): \(response.error.message) \(response.error.systemMessage)" : nil)
            return response
        } catch {
            APILog.record(name, request: request, started: started, response: Res?.none, error: String(describing: error))
            throw error
        }
    }

    /// Без авторизации.
    private func call<Req: Message, Res: HasErrorField & Message>(
        _ name: String, _ request: Req, _ perform: (GRPCClient<HTTP2ClientTransport.Posix>, Req) async throws -> Res
    ) async throws -> Res {
        let client = try grpc()
        return try unwrap(try await logged(name, request) { try await perform(client, request) })
    }

    /// С авторизацией: подставляет токен, при `NeedToRefreshToken` обновляет его и повторяет один раз.
    private func authed<Req: HasAccessToken & Message, Res: HasErrorField & Message>(
        _ name: String, _ request: Req,
        _ perform: (GRPCClient<HTTP2ClientTransport.Posix>, Req) async throws -> Res
    ) async throws -> Res {
        var request = request
        request.accessToken = try await validAccessToken()
        let client = try grpc()
        let sent = request
        var response = try await logged(name, sent) { try await perform(client, sent) }
        if response.hasError, APIError(response.error).category == .needToRefreshToken {
            request.accessToken = try await refreshTokens()
            let retried = request
            response = try await logged(name, retried) { try await perform(try grpc(), retried) }
        }
        if response.hasError {
            let error = APIError(response.error)
            if error.category == .needToLogout { onLogout?() }
            throw error
        }
        return response
    }

    // MARK: - Токены

    private func validAccessToken() async throws -> String {
        guard let token = TokenStore.accessToken else { throw APIError(message: "Не выполнен вход", category: .needToLogout) }
        if let exp = Self.expiration(of: token), exp < Date().addingTimeInterval(30) {
            return try await refreshTokens()
        }
        return token
    }

    /// `exp` из JWT без проверки подписи — только чтобы не слать заведомо протухший токен.
    static func expiration(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func refreshTokens() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task<String, Error> {
            guard let refresh = TokenStore.refreshToken else { throw APIError(message: "Не выполнен вход", category: .needToLogout) }
            var request = Auth_RefreshTokensRequest()
            request.token = refresh
            request.application = Self.application
            request.device = await Self.device()
            let client = try grpc()
            let response = try await logged("RefreshTokens", request) {
                try await Auth_AuthEndpoint.Client(wrapping: client).refreshTokens(request)
            }
            if response.hasError {
                let error = APIError(response.error)
                if error.category == .needToLogout { onLogout?() }
                throw error
            }
            TokenStore.accessToken = response.accessToken
            TokenStore.refreshToken = response.refreshToken
            return response.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private static var application: Auth_ApplicationInformation {
        var app = Auth_ApplicationInformation()
        app.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        app.build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        app.bundleID = Bundle.main.bundleIdentifier ?? ""
        return app
    }

    @MainActor private static func device() -> Auth_DeviceInformation {
        var device = Auth_DeviceInformation()
        device.deviceName = UIDevice.current.name
        device.modelName = UIDevice.current.model
        #if targetEnvironment(macCatalyst)
        device.nameOs = .osx
        #else
        device.nameOs = UIDevice.current.userInterfaceIdiom == .pad ? .ipadOs : .ios
        #endif
        device.versionOs = UIDevice.current.systemVersion
        return device
    }

    // MARK: - Авторизация

    func signIn(email: String, password: String) async throws {
        var request = Auth_SignInRequest()
        request.email = email
        request.password = password
        request.application = Self.application
        request.device = await Self.device()
        request.deviceID = TokenStore.deviceID
        let response = try await call("SignIn", request) { try await Auth_AuthEndpoint.Client(wrapping: $0).signIn($1) }
        TokenStore.accessToken = response.token.accessToken
        TokenStore.refreshToken = response.token.refreshToken
        TokenStore.email = email
    }

    func signOut() async {
        guard TokenStore.accessToken != nil else { return }
        _ = try? await authed("SignOut", Auth_SignOutRequest()) { try await Auth_AuthEndpoint.Client(wrapping: $0).signOut($1) }
    }

    /// Смена пароля — сразу онлайн, не через очередь.
    func changePassword(old: String, new: String) async throws {
        var request = User_UpdateUserRequest()
        request.oldPassword = old
        request.newPassword = new
        _ = try await authed("UpdateUser", request) { try await User_UserEndpoint.Client(wrapping: $0).updateUser($1) }
    }

    // MARK: - Синк

    func sync(since: UInt32) async throws -> SyncChanges {
        var request = Sync_SyncRequest()
        request.sinceID = since
        let response = try await authed("Sync", request) { try await Sync_SyncEndpoint.Client(wrapping: $0).sync($1) }
        return try SyncChanges(proto: response)
    }

    func confirmSync(token: Data) async throws {
        var request = Sync_ConfirmSyncRequest()
        request.pendingSyncToken = token
        _ = try await authed("ConfirmSync", request) { try await Sync_SyncEndpoint.Client(wrapping: $0).confirmSync($1) }
    }

    /// Ждёт уведомлений о новых изменениях и зовёт `onChange` на каждое; возвращается, когда стрим закрылся.
    func subscribe(onChange: @escaping @Sendable () async -> Void) async throws {
        var request = Sync_SubscribeToSyncRequest()
        request.accessToken = try await validAccessToken()
        let client = Sync_SyncEndpoint.Client(wrapping: try grpc())
        let started = ContinuousClock.now
        let sent = request
        do {
            try await client.subscribeToSync(request) { response in
                for try await message in response.messages {
                    APILog.record("SubscribeToSync ↓", request: sent, started: started, response: message, error: nil)
                    await onChange()
                }
            }
            APILog.record("SubscribeToSync", request: request, started: started, response: Sync_SubscribeToSyncRequest?.none, error: "стрим закрыт")
        } catch {
            APILog.record("SubscribeToSync", request: request, started: started, response: Sync_SubscribeToSyncRequest?.none, error: String(describing: error))
            throw error
        }
    }

    // MARK: - Правки очереди

    func send(_ mutation: Mutation) async throws {
        switch mutation {
        case .createList(let v):
            var r = TaskList_CreateTaskListRequest()
            r.id = v.id.protoData; r.name = v.name; r.colorHex = v.colorHex; r.icon = v.icon
            r.sortOrder = v.sortOrder; r.sortMode = v.sortMode.proto; r.createdAt = v.updatedAt.proto
            _ = try await authed("CreateTaskList", r) { try await TaskList_TaskListEndpoint.Client(wrapping: $0).createTaskList($1) }
        case .updateList(let v):
            var r = TaskList_UpdateTaskListRequest()
            r.id = v.id.protoData; r.name = v.name; r.colorHex = v.colorHex; r.icon = v.icon
            r.sortOrder = v.sortOrder; r.sortMode = v.sortMode.proto; r.updatedAt = v.updatedAt.proto
            _ = try await authed("UpdateTaskList", r) { try await TaskList_TaskListEndpoint.Client(wrapping: $0).updateTaskList($1) }
        case .deleteList(let id, let at):
            var r = TaskList_DeleteTaskListRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("DeleteTaskList", r) { try await TaskList_TaskListEndpoint.Client(wrapping: $0).deleteTaskList($1) }

        case .createSection(let v):
            var r = ListSection_CreateListSectionRequest()
            r.id = v.id.protoData; r.listID = v.listId.protoData; r.name = v.name; r.sortOrder = v.sortOrder; r.updatedAt = v.updatedAt.proto
            _ = try await authed("CreateListSection", r) { try await ListSection_ListSectionEndpoint.Client(wrapping: $0).createListSection($1) }
        case .updateSection(let v):
            var r = ListSection_UpdateListSectionRequest()
            r.id = v.id.protoData; r.listID = v.listId.protoData; r.name = v.name; r.sortOrder = v.sortOrder; r.updatedAt = v.updatedAt.proto
            _ = try await authed("UpdateListSection", r) { try await ListSection_ListSectionEndpoint.Client(wrapping: $0).updateListSection($1) }
        case .deleteSection(let id, let at):
            var r = ListSection_DeleteListSectionRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("DeleteListSection", r) { try await ListSection_ListSectionEndpoint.Client(wrapping: $0).deleteListSection($1) }

        case .createPriority(let v):
            var r = Priority_CreatePriorityRequest()
            r.id = v.id.protoData; r.name = v.name; r.colorHex = v.colorHex; r.marks = v.marks; r.sortOrder = v.sortOrder; r.updatedAt = v.updatedAt.proto
            _ = try await authed("CreatePriority", r) { try await Priority_PriorityEndpoint.Client(wrapping: $0).createPriority($1) }
        case .updatePriority(let v):
            var r = Priority_UpdatePriorityRequest()
            r.id = v.id.protoData; r.name = v.name; r.colorHex = v.colorHex; r.marks = v.marks; r.sortOrder = v.sortOrder; r.updatedAt = v.updatedAt.proto
            _ = try await authed("UpdatePriority", r) { try await Priority_PriorityEndpoint.Client(wrapping: $0).updatePriority($1) }
        case .deletePriority(let id, let at):
            var r = Priority_DeletePriorityRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("DeletePriority", r) { try await Priority_PriorityEndpoint.Client(wrapping: $0).deletePriority($1) }

        case .createDuration(let v):
            var r = DurationOption_CreateDurationOptionRequest()
            r.id = v.id.protoData; r.title = v.title; r.minutes = Int32(v.minutes); r.updatedAt = v.updatedAt.proto
            _ = try await authed("CreateDurationOption", r) { try await DurationOption_DurationOptionEndpoint.Client(wrapping: $0).createDurationOption($1) }
        case .updateDuration(let v):
            var r = DurationOption_UpdateDurationOptionRequest()
            r.id = v.id.protoData; r.title = v.title; r.minutes = Int32(v.minutes); r.updatedAt = v.updatedAt.proto
            _ = try await authed("UpdateDurationOption", r) { try await DurationOption_DurationOptionEndpoint.Client(wrapping: $0).updateDurationOption($1) }
        case .deleteDuration(let id, let at):
            var r = DurationOption_DeleteDurationOptionRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("DeleteDurationOption", r) { try await DurationOption_DurationOptionEndpoint.Client(wrapping: $0).deleteDurationOption($1) }

        case .createTask(let v):
            var r = Task_CreateTaskRequest()
            r.id = v.id.protoData; r.listID = v.listId.protoData
            if let s = v.sectionId { r.sectionID = s.protoData }
            r.title = v.title; r.notes = v.notes
            if let p = v.priorityId { r.priorityID = p.protoData }
            if let d = v.plannedDay { r.plannedDay = d }
            if let d = v.deadlineDay { r.deadlineDay = d }
            if let m = v.durationMinutes { r.durationMinutes = Int32(m) }
            r.manualOrder = v.manualOrder
            if let e = v.externalId { r.externalID = e }
            r.createdAt = v.updatedAt.proto
            _ = try await authed("CreateTask", r) { try await Task_TaskEndpoint.Client(wrapping: $0).createTask($1) }
        case .updateTask(let v):
            // Все поля снимка: пустое значение сбрасывает поле на сервере
            var r = Task_UpdateTaskRequest()
            r.id = v.id.protoData; r.listID = v.listId.protoData
            r.sectionID = v.sectionId?.protoData ?? Data()
            r.title = v.title; r.notes = v.notes
            r.priorityID = v.priorityId?.protoData ?? Data()
            r.plannedDay = v.plannedDay ?? ""
            r.deadlineDay = v.deadlineDay ?? ""
            r.durationMinutes = Int32(v.durationMinutes ?? 0)
            r.manualOrder = v.manualOrder
            r.updatedAt = v.updatedAt.proto
            _ = try await authed("UpdateTask", r) { try await Task_TaskEndpoint.Client(wrapping: $0).updateTask($1) }
        case .setCompleted(let id, let completed, let at):
            var r = Task_SetTaskCompletedRequest()
            r.id = id.protoData; r.completed = completed; r.updatedAt = at.proto
            _ = try await authed("SetTaskCompleted", r) { try await Task_TaskEndpoint.Client(wrapping: $0).setTaskCompleted($1) }
        case .deleteTask(let id, let at):
            var r = Task_DeleteTaskRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("DeleteTask", r) { try await Task_TaskEndpoint.Client(wrapping: $0).deleteTask($1) }

        case .createTag(let v):
            var r = Tag_CreateTagRequest()
            r.id = v.id.protoData; r.name = v.name; r.updatedAt = v.updatedAt.proto
            _ = try await authed("CreateTag", r) { try await Tag_TagEndpoint.Client(wrapping: $0).createTag($1) }
        case .updateTag(let v):
            var r = Tag_UpdateTagRequest()
            r.id = v.id.protoData; r.name = v.name; r.updatedAt = v.updatedAt.proto
            _ = try await authed("UpdateTag", r) { try await Tag_TagEndpoint.Client(wrapping: $0).updateTag($1) }
        case .deleteTag(let id, let at):
            var r = Tag_DeleteTagRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("DeleteTag", r) { try await Tag_TagEndpoint.Client(wrapping: $0).deleteTag($1) }
        case .addTag(let task, let tag, let at):
            var r = Tag_AddTagToTaskRequest()
            r.taskID = task.protoData; r.tagID = tag.protoData; r.updatedAt = at.proto
            _ = try await authed("AddTagToTask", r) { try await Tag_TagEndpoint.Client(wrapping: $0).addTagToTask($1) }
        case .removeTag(let task, let tag, let at):
            var r = Tag_RemoveTagFromTaskRequest()
            r.taskID = task.protoData; r.tagID = tag.protoData; r.updatedAt = at.proto
            _ = try await authed("RemoveTagFromTask", r) { try await Tag_TagEndpoint.Client(wrapping: $0).removeTagFromTask($1) }

        case .createBlocker(let v):
            var r = Blocker_CreateBlockerRequest()
            r.id = v.id.protoData; r.taskID = v.taskId.protoData
            if let b = v.blockingTaskId { r.blockingTaskID = b.protoData }
            if let reason = v.reason { r.reason = reason }
            r.sinceDay = v.sinceDay; r.updatedAt = v.updatedAt.proto
            _ = try await authed("CreateBlocker", r) { try await Blocker_BlockerEndpoint.Client(wrapping: $0).createBlocker($1) }
        case .resolveBlocker(let id, let at):
            var r = Blocker_ResolveBlockerRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("ResolveBlocker", r) { try await Blocker_BlockerEndpoint.Client(wrapping: $0).resolveBlocker($1) }
        case .deleteBlocker(let id, let at):
            var r = Blocker_DeleteBlockerRequest()
            r.id = id.protoData; r.updatedAt = at.proto
            _ = try await authed("DeleteBlocker", r) { try await Blocker_BlockerEndpoint.Client(wrapping: $0).deleteBlocker($1) }

        case .updateSettings(let minutes, let at):
            var r = Settings_UpdateSettingsRequest()
            r.dailyCapacityMinutes = UInt32(max(0, minutes)); r.updatedAt = at.proto
            _ = try await authed("UpdateSettings", r) { try await Settings_SettingsEndpoint.Client(wrapping: $0).updateSettings($1) }
        }
    }
}

// MARK: - Соответствие запросов и ответов

extension Auth_SignOutRequest: HasAccessToken {}
extension User_UpdateUserRequest: HasAccessToken {}
extension Sync_SyncRequest: HasAccessToken {}
extension Sync_ConfirmSyncRequest: HasAccessToken {}
extension TaskList_CreateTaskListRequest: HasAccessToken {}
extension TaskList_UpdateTaskListRequest: HasAccessToken {}
extension TaskList_DeleteTaskListRequest: HasAccessToken {}
extension ListSection_CreateListSectionRequest: HasAccessToken {}
extension ListSection_UpdateListSectionRequest: HasAccessToken {}
extension ListSection_DeleteListSectionRequest: HasAccessToken {}
extension Priority_CreatePriorityRequest: HasAccessToken {}
extension Priority_UpdatePriorityRequest: HasAccessToken {}
extension Priority_DeletePriorityRequest: HasAccessToken {}
extension DurationOption_CreateDurationOptionRequest: HasAccessToken {}
extension DurationOption_UpdateDurationOptionRequest: HasAccessToken {}
extension DurationOption_DeleteDurationOptionRequest: HasAccessToken {}
extension Task_CreateTaskRequest: HasAccessToken {}
extension Task_UpdateTaskRequest: HasAccessToken {}
extension Task_SetTaskCompletedRequest: HasAccessToken {}
extension Task_DeleteTaskRequest: HasAccessToken {}
extension Tag_CreateTagRequest: HasAccessToken {}
extension Tag_UpdateTagRequest: HasAccessToken {}
extension Tag_DeleteTagRequest: HasAccessToken {}
extension Tag_AddTagToTaskRequest: HasAccessToken {}
extension Tag_RemoveTagFromTaskRequest: HasAccessToken {}
extension Blocker_CreateBlockerRequest: HasAccessToken {}
extension Blocker_ResolveBlockerRequest: HasAccessToken {}
extension Blocker_DeleteBlockerRequest: HasAccessToken {}
extension Settings_UpdateSettingsRequest: HasAccessToken {}

extension Auth_SignInResponse: HasErrorField {}
extension Auth_RefreshTokensResponse: HasErrorField {}
extension Auth_SignOutResponse: HasErrorField {}
extension User_UpdateUserResponse: HasErrorField {}
extension Sync_SyncResponse: HasErrorField {}
extension Sync_ConfirmSyncResponse: HasErrorField {}
extension TaskList_CreateTaskListResponse: HasErrorField {}
extension TaskList_UpdateTaskListResponse: HasErrorField {}
extension TaskList_DeleteTaskListResponse: HasErrorField {}
extension ListSection_CreateListSectionResponse: HasErrorField {}
extension ListSection_UpdateListSectionResponse: HasErrorField {}
extension ListSection_DeleteListSectionResponse: HasErrorField {}
extension Priority_CreatePriorityResponse: HasErrorField {}
extension Priority_UpdatePriorityResponse: HasErrorField {}
extension Priority_DeletePriorityResponse: HasErrorField {}
extension DurationOption_CreateDurationOptionResponse: HasErrorField {}
extension DurationOption_UpdateDurationOptionResponse: HasErrorField {}
extension DurationOption_DeleteDurationOptionResponse: HasErrorField {}
extension Task_CreateTaskResponse: HasErrorField {}
extension Task_UpdateTaskResponse: HasErrorField {}
extension Task_SetTaskCompletedResponse: HasErrorField {}
extension Task_DeleteTaskResponse: HasErrorField {}
extension Tag_CreateTagResponse: HasErrorField {}
extension Tag_UpdateTagResponse: HasErrorField {}
extension Tag_DeleteTagResponse: HasErrorField {}
extension Tag_AddTagToTaskResponse: HasErrorField {}
extension Tag_RemoveTagFromTaskResponse: HasErrorField {}
extension Blocker_CreateBlockerResponse: HasErrorField {}
extension Blocker_ResolveBlockerResponse: HasErrorField {}
extension Blocker_DeleteBlockerResponse: HasErrorField {}
extension Settings_UpdateSettingsResponse: HasErrorField {}
