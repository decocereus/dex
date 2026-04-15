import Foundation

struct DexDesktopResolvedConnection {
    let session: DexDesktopBrowserSession
    let client: DexCompanionClient
}

final class DexDesktopRuntimeService {
    static let shared = DexDesktopRuntimeService()

    private var threadStreamTask: Task<Void, Never>?
    private var threadStreamKey: ThreadKey?

    deinit {
        threadStreamTask?.cancel()
    }

    func resolveConnection(forServerId serverId: String) -> DexDesktopResolvedConnection? {
        guard let session = DexDesktopRouting.browserSession(forServerId: serverId) else {
            return nil
        }
        return DexDesktopResolvedConnection(
            session: session,
            client: DexCompanionClient(
                httpBaseUrl: session.httpBaseUrl,
                bearerToken: session.bearerToken
            )
        )
    }

    func fetchThreadSnapshot(
        key: ThreadKey
    ) async throws -> (connection: DexDesktopResolvedConnection, snapshot: DexNativeThreadSnapshot) {
        guard let connection = resolveConnection(forServerId: key.serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        let snapshot = try await connection.client.fetchNativeThreadSnapshot(threadId: key.threadId)
        return (connection, snapshot)
    }

    func fetchAuthSessionState(serverId: String) async throws -> DexAuthSessionState {
        guard let connection = resolveConnection(forServerId: serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        return try await connection.client.fetchAuthSessionState()
    }

    func createThread(
        serverId: String,
        projectId: String,
        title: String,
        modelSelection: [String: Any]?,
        runtimeMode: String,
        interactionMode: String,
        worktreePath: String?
    ) async throws -> (connection: DexDesktopResolvedConnection, snapshot: DexNativeThreadSnapshot) {
        guard let connection = resolveConnection(forServerId: serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        let snapshot = try await connection.client.createNativeThread(
            projectId: projectId,
            title: title,
            modelSelection: modelSelection,
            runtimeMode: runtimeMode,
            interactionMode: interactionMode,
            branch: nil,
            worktreePath: worktreePath
        )
        return (connection, snapshot)
    }

    func configureThread(
        key: ThreadKey,
        title: String? = nil,
        modelSelection: [String: Any]? = nil,
        runtimeMode: String? = nil,
        interactionMode: String? = nil
    ) async throws -> (connection: DexDesktopResolvedConnection, snapshot: DexNativeThreadSnapshot) {
        guard let connection = resolveConnection(forServerId: key.serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        let snapshot = try await connection.client.configureNativeThread(
            threadId: key.threadId,
            title: title,
            modelSelection: modelSelection,
            runtimeMode: runtimeMode,
            interactionMode: interactionMode
        )
        return (connection, snapshot)
    }

    func interruptTurn(key: ThreadKey, turnId: String) async throws {
        guard let connection = resolveConnection(forServerId: key.serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        _ = try await connection.client.dispatchCommand([
            "type": "thread.turn.interrupt",
            "commandId": UUID().uuidString,
            "threadId": key.threadId,
            "turnId": turnId,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ])
    }

    func respondToApproval(
        key: ThreadKey,
        requestId: String,
        decision: String
    ) async throws {
        guard let connection = resolveConnection(forServerId: key.serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        _ = try await connection.client.dispatchCommand([
            "type": "thread.approval.respond",
            "commandId": UUID().uuidString,
            "threadId": key.threadId,
            "requestId": requestId,
            "decision": decision,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ])
    }

    func respondToUserInput(
        key: ThreadKey,
        requestId: String,
        answers: [String: [String]]
    ) async throws {
        guard let connection = resolveConnection(forServerId: key.serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        _ = try await connection.client.dispatchCommand([
            "type": "thread.user-input.respond",
            "commandId": UUID().uuidString,
            "threadId": key.threadId,
            "requestId": requestId,
            "answers": answers,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ])
    }

    func archiveThread(key: ThreadKey) async throws {
        guard let connection = resolveConnection(forServerId: key.serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        _ = try await connection.client.archiveNativeThread(threadId: key.threadId)
    }

    func dispatchTurnStart(
        key: ThreadKey,
        text: String,
        attachments: [[String: Any]],
        modelSelection: [String: Any]?,
        runtimeMode: String,
        interactionMode: String
    ) async throws {
        guard let connection = resolveConnection(forServerId: key.serverId) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        var command: [String: Any] = [
            "type": "thread.turn.start",
            "commandId": UUID().uuidString,
            "threadId": key.threadId,
            "message": [
                "messageId": UUID().uuidString,
                "role": "user",
                "text": text,
                "attachments": attachments,
            ],
            "runtimeMode": runtimeMode,
            "interactionMode": interactionMode,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let modelSelection {
            command["modelSelection"] = modelSelection
        }
        _ = try await connection.client.dispatchCommand(command)
    }

    func stopThreadStream() -> ThreadKey? {
        let previousKey = threadStreamKey
        threadStreamTask?.cancel()
        threadStreamTask = nil
        threadStreamKey = nil
        return previousKey
    }

    func stopThreadStreamIfMatching(_ key: ThreadKey) {
        guard threadStreamKey == key else { return }
        _ = stopThreadStream()
    }

    func startThreadStream(
        key: ThreadKey,
        onSnapshot: @escaping @Sendable @MainActor (DexDesktopResolvedConnection, DexNativeThreadSnapshot) -> Void,
        onNonFatalError: @escaping @Sendable @MainActor (Error) -> Void,
        onReconnectableError: @escaping @Sendable @MainActor (NSError) -> Void
    ) -> Bool {
        guard DexDesktopRouting.environmentId(fromServerId: key.serverId) != nil else {
            _ = stopThreadStream()
            return false
        }
        guard threadStreamKey != key else { return false }

        threadStreamTask?.cancel()
        threadStreamKey = key
        threadStreamTask = Task {
            guard let connection = self.resolveConnection(forServerId: key.serverId) else {
                return
            }

            while !Task.isCancelled {
                do {
                    try await connection.client.streamNativeThreadSnapshots(threadId: key.threadId) { snapshot in
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            onSnapshot(connection, snapshot)
                        }
                    }
                    break
                } catch {
                    if Task.isCancelled {
                        break
                    }
                    let nsError = error as NSError
                    let isReconnectable =
                        nsError.domain == NSURLErrorDomain &&
                        (nsError.code == NSURLErrorTimedOut ||
                            nsError.code == NSURLErrorCannotConnectToHost ||
                            nsError.code == NSURLErrorNetworkConnectionLost)

                    if isReconnectable {
                        await MainActor.run {
                            onReconnectableError(nsError)
                        }
                    } else {
                        await MainActor.run {
                            onNonFatalError(error)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        return true
    }
}

typealias DexCompanionResolvedConnection = DexDesktopResolvedConnection
typealias DexCompanionRuntimeService = DexDesktopRuntimeService
