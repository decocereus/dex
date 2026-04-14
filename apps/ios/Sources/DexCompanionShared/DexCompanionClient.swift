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
}
