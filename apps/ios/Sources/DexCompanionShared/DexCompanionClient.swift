import Foundation

struct DexCompanionShellProject: Codable, Equatable {
    let id: String
    let title: String
    let workspaceRoot: String
}

struct DexCompanionLatestTurn: Codable, Equatable {
    let turnId: String
    let state: String
    let requestedAt: String
    let startedAt: String?
    let completedAt: String?
    let assistantMessageId: String?
}

struct DexCompanionThreadShell: Codable, Equatable {
    let id: String
    let projectId: String
    let title: String
    let branch: String?
    let worktreePath: String?
    let latestTurn: DexCompanionLatestTurn?
    let createdAt: String
    let updatedAt: String
    let archivedAt: String?
    let latestUserMessageAt: String?
    let hasPendingApprovals: Bool
    let hasPendingUserInput: Bool
    let hasActionableProposedPlan: Bool
}

struct DexCompanionShellSnapshot: Codable, Equatable {
    let snapshotSequence: UInt64
    let projects: [DexCompanionShellProject]
    let threads: [DexCompanionThreadShell]
    let updatedAt: String
}

struct DexNativeScopedThreadRef: Codable, Equatable {
    let environmentId: String
    let threadId: String
}

struct DexNativeProjectShell: Codable, Equatable {
    let id: String
    let title: String
    let workspaceRoot: String
}

struct DexNativeSessionSummary: Codable, Equatable {
    let threadRef: DexNativeScopedThreadRef
    let projectId: String
    let title: String
    let preview: String
    let cwd: String?
    let branch: String?
    let model: String
    let modelProvider: String
    let runtimeMode: String
    let interactionMode: String
    let updatedAt: String
    let archivedAt: String?
    let latestUserMessageAt: String?
    let hasActiveTurn: Bool
    let hasPendingApprovals: Bool
    let hasPendingUserInput: Bool
    let isSubagent: Bool
    let isFork: Bool
    let parentThreadId: String?
    let agentNickname: String?
    let agentRole: String?
    let agentDisplayLabel: String?
    let agentStatus: String?
}

struct DexNativeEnvironmentDescriptor: Codable, Equatable {
    let environmentId: String
    let label: String
}

struct DexAuthSessionState: Codable, Equatable {
    struct AuthDescriptor: Codable, Equatable {
        let policy: String
    }

    let authenticated: Bool
    let auth: AuthDescriptor
    let role: String?
    let sessionMethod: String?
    let expiresAt: String?
}

struct DexNativeShellSnapshot: Codable, Equatable {
    let environment: DexNativeEnvironmentDescriptor
    let projects: [DexNativeProjectShell]
    let sessionSummaries: [DexNativeSessionSummary]
    let updatedAt: String
}

struct DexNativePendingApproval: Codable, Equatable {
    let requestId: String
    let turnId: String?
    let requestKind: String?
    let requestType: String?
    let detail: String?
    let createdAt: String
}

struct DexNativeUserInputOption: Codable, Equatable {
    let label: String
    let description: String?
}

struct DexNativeUserInputQuestion: Codable, Equatable {
    let id: String
    let header: String?
    let question: String
    let options: [DexNativeUserInputOption]
    let multiSelect: Bool
}

struct DexNativePendingUserInput: Codable, Equatable {
    let requestId: String
    let turnId: String?
    let createdAt: String
    let questions: [DexNativeUserInputQuestion]
}

private struct DexNativeFileSearchRequest: Encodable {
    let cwd: String
    let query: String
    let limit: Int
}

private struct DexNativeFileSearchResponse: Decodable {
    let results: [DexNativeFileSearchResult]
}

private struct DexNativeFileSearchResult: Decodable {
    let root: String
    let path: String
    let matchType: String
    let fileName: String
    let score: UInt32
    let indices: [UInt32]?
}

private struct DexNativeSkillsRequest: Encodable {
    let cwd: String
    let forceReload: Bool
}

private struct DexNativeSkillsResponse: Decodable {
    let skills: [DexNativeSkillRecord]
}

private struct DexNativeSkillRecord: Decodable {
    let name: String
    let description: String?
    let path: String
    let scope: String?
    let enabled: Bool
    let displayName: String?
    let shortDescription: String?
}

struct DexNativeOrchestrationMessage: Codable, Equatable {
    let id: String
    let role: String
    let text: String
    let turnId: String?
    let streaming: Bool
    let createdAt: String
    let updatedAt: String
}

struct DexNativeCodexModelOptions: Codable, Equatable {
    let reasoningEffort: String?
    let fastMode: Bool?
}

struct DexNativeProviderModelOptions: Codable, Equatable {
    let codex: DexNativeCodexModelOptions?
}

struct DexNativeModelSelection: Codable, Equatable {
    let provider: String
    let model: String
    let options: DexNativeProviderModelOptions?
}

struct DexNativeOrchestrationThread: Codable, Equatable {
    let id: String
    let projectId: String
    let title: String
    let modelSelection: DexNativeModelSelection?
    let runtimeMode: String?
    let interactionMode: String?
    let branch: String?
    let worktreePath: String?
    let latestTurn: DexCompanionLatestTurn?
    let messages: [DexNativeOrchestrationMessage]
}

struct DexNativeThreadSnapshot: Codable, Equatable {
    let environment: DexNativeEnvironmentDescriptor
    let summary: DexNativeSessionSummary
    let thread: DexNativeOrchestrationThread
    let pendingApprovals: [DexNativePendingApproval]
    let pendingUserInputs: [DexNativePendingUserInput]
    let updatedAt: String
}

struct DexCompanionThreadDetail: Codable, Equatable {
    let id: String
    let projectId: String
    let title: String
    let branch: String?
    let worktreePath: String?
    let createdAt: String
    let updatedAt: String
    let archivedAt: String?
}

struct DexCompanionDispatchResponse: Codable, Equatable {
    let sequence: UInt64
}

enum DexCompanionClientError: LocalizedError {
    case invalidBaseUrl
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseUrl:
            return "The Dex companion server URL is invalid."
        case .invalidResponse:
            return "Dex returned an invalid response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct DexCompanionClient {
    let httpBaseUrl: String
    let bearerToken: String

    func fetchShellSnapshot() async throws -> DexCompanionShellSnapshot {
        try await request(path: "api/companion/shell", method: "GET")
    }

    func fetchThreadDetail(threadId: String) async throws -> DexCompanionThreadDetail {
        try await request(path: "api/companion/thread", queryItems: [URLQueryItem(name: "threadId", value: threadId)], method: "GET")
    }

    func fetchNativeShellSnapshot() async throws -> DexNativeShellSnapshot {
        try await request(path: "api/companion/native/shell", method: "GET")
    }

    func fetchNativeThreadSnapshot(threadId: String) async throws -> DexNativeThreadSnapshot {
        try await request(
            path: "api/companion/native/thread",
            queryItems: [URLQueryItem(name: "threadId", value: threadId)],
            method: "GET"
        )
    }

    func fetchAuthSessionState() async throws -> DexAuthSessionState {
        try await request(path: "api/auth/session", method: "GET")
    }

    func createNativeThread(
        projectId: String,
        title: String?,
        modelSelection: [String: Any]?,
        runtimeMode: String,
        interactionMode: String,
        branch: String?,
        worktreePath: String?
    ) async throws -> DexNativeThreadSnapshot {
        var requestBody: [String: Any] = [
            "projectId": projectId,
            "runtimeMode": runtimeMode,
            "interactionMode": interactionMode,
        ]
        if let title {
            requestBody["title"] = title
        }
        if let modelSelection {
            requestBody["modelSelection"] = modelSelection
        }
        if let branch {
            requestBody["branch"] = branch
        }
        if let worktreePath {
            requestBody["worktreePath"] = worktreePath
        }
        return try await request(
            path: "api/companion/native/thread/create",
            method: "POST",
            bodyData: try JSONSerialization.data(withJSONObject: requestBody)
        )
    }

    func configureNativeThread(
        threadId: String,
        title: String? = nil,
        modelSelection: [String: Any]? = nil,
        runtimeMode: String? = nil,
        interactionMode: String? = nil
    ) async throws -> DexNativeThreadSnapshot {
        var requestBody: [String: Any] = ["threadId": threadId]
        if let title {
            requestBody["title"] = title
        }
        if let modelSelection {
            requestBody["modelSelection"] = modelSelection
        }
        if let runtimeMode {
            requestBody["runtimeMode"] = runtimeMode
        }
        if let interactionMode {
            requestBody["interactionMode"] = interactionMode
        }
        return try await request(
            path: "api/companion/native/thread/configure",
            method: "POST",
            bodyData: try JSONSerialization.data(withJSONObject: requestBody)
        )
    }

    func archiveNativeThread(threadId: String) async throws -> DexCompanionDispatchResponse {
        try await request(
            path: "api/companion/native/thread/archive",
            method: "POST",
            bodyData: try JSONSerialization.data(withJSONObject: ["threadId": threadId])
        )
    }

    func searchNativeFiles(
        cwd: String,
        query: String,
        limit: Int = 50
    ) async throws -> [FileSearchResult] {
        let response: DexNativeFileSearchResponse = try await request(
            path: "api/companion/native/files/search",
            method: "POST",
            bodyData: try JSONEncoder().encode(
                DexNativeFileSearchRequest(cwd: cwd, query: query, limit: limit)
            )
        )
        return response.results.map { result in
            FileSearchResult(
                root: result.root,
                path: result.path,
                matchType: result.matchType == "directory" ? .directory : .file,
                fileName: result.fileName,
                score: result.score,
                indices: result.indices
            )
        }
    }

    func listNativeSkills(
        cwd: String,
        forceReload: Bool
    ) async throws -> [SkillMetadata] {
        let response: DexNativeSkillsResponse = try await request(
            path: "api/companion/native/skills/list",
            method: "POST",
            bodyData: try JSONEncoder().encode(
                DexNativeSkillsRequest(cwd: cwd, forceReload: forceReload)
            )
        )
        return response.skills.map { skill in
            SkillMetadata(
                name: skill.name,
                description: skill.description ?? "",
                shortDescription: skill.shortDescription,
                interface: SkillInterface(
                    displayName: skill.displayName,
                    shortDescription: skill.shortDescription,
                    iconSmall: nil,
                    iconLarge: nil,
                    brandColor: nil,
                    defaultPrompt: nil
                ),
                dependencies: nil,
                path: AbsolutePath(value: skill.path),
                scope: dexSkillScope(from: skill.scope),
                enabled: skill.enabled
            )
        }
    }

    func streamNativeThreadSnapshots(
        threadId: String,
        onSnapshot: @escaping @Sendable (DexNativeThreadSnapshot) async -> Void
    ) async throws {
        guard let baseUrl = URL(string: httpBaseUrl) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        var components = URLComponents(
            url: baseUrl.appending(path: "api/companion/native/thread/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "threadId", value: threadId)]
        guard let url = components?.url else {
            throw DexCompanionClientError.invalidBaseUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60 * 60 * 24

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DexCompanionClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw DexCompanionClientError.requestFailed("Dex thread stream failed.")
        }

        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let snapshot = try? decoder.decode(DexNativeThreadSnapshot.self, from: data) else {
                continue
            }
            await onSnapshot(snapshot)
        }
    }

    func dispatchCommand(_ payload: [String: Any]) async throws -> DexCompanionDispatchResponse {
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        return try await request(
            path: "api/companion/dispatch",
            method: "POST",
            bodyData: bodyData
        )
    }

    private func request<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        bodyData: Data? = nil
    ) async throws -> Response {
        guard let baseUrl = URL(string: httpBaseUrl) else {
            throw DexCompanionClientError.invalidBaseUrl
        }
        var components = URLComponents(url: baseUrl.appending(path: path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw DexCompanionClientError.invalidBaseUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DexCompanionClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DexCompanionClientError.requestFailed(message ?? "Dex request failed.")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw DexCompanionClientError.invalidResponse
        }
        return decoded
    }

    private func dexSkillScope(from value: String?) -> SkillScope {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "repo":
            return .repo
        case "system":
            return .system
        case "admin":
            return .admin
        default:
            return .user
        }
    }
}
