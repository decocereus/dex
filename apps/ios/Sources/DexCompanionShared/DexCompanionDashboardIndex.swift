import Foundation
import SwiftUI

@MainActor
enum DexCompanionDashboardIndex {
    struct Snapshot: Equatable {
        let connectedServers: [HomeDashboardServer]
        let recentSessions: [HomeDashboardRecentSession]
    }

    static func load(limit: Int = 10) async -> Snapshot {
        let savedSessions = DexCompanionSessionStore.load()
        var connectedServers: [HomeDashboardServer] = []
        var recentSessions: [HomeDashboardRecentSession] = []

        for savedSession in savedSessions {
            guard let browserSession = savedSession.makeBrowserSession() else {
                DexCompanionSessionStore.remove(environmentId: savedSession.environmentId)
                continue
            }

            let client = DexCompanionClient(
                httpBaseUrl: browserSession.httpBaseUrl,
                bearerToken: browserSession.bearerToken
            )

            guard let shellSnapshot = try? await client.fetchShellSnapshot() else {
                continue
            }

            let serverId = dexServerId(for: savedSession.environmentId)
            let host = URL(string: browserSession.httpBaseUrl)?.host ?? "dex"
            let port = UInt16(URL(string: browserSession.httpBaseUrl)?.port ?? 443)
            let sortedThreads = shellSnapshot.threads.sorted {
                parseDate($0.updatedAt) > parseDate($1.updatedAt)
            }
            let latestThread = sortedThreads.first
            let latestProject = latestThread.flatMap { thread in
                shellSnapshot.projects.first(where: { $0.id == thread.projectId })
            } ?? shellSnapshot.projects.first

            let serverLaunchSession = browserSession.withNavigation(
                initialPath: latestThread.map {
                    dexThreadPath(environmentId: browserSession.environmentId, threadId: $0.id)
                } ?? dexChatRootPath(),
                navigationTitle: browserSession.serverLabel
            )

            connectedServers.append(
                HomeDashboardServer(
                    id: serverId,
                    displayName: browserSession.serverLabel,
                    host: host,
                    port: port,
                    isLocal: false,
                    hasIpc: false,
                    health: .connected,
                    sourceLabel: "Dex Companion",
                    statusLabel: "Connected",
                    statusColor: LitterTheme.accent,
                    projectName: latestProject?.title,
                    latestThreadTitle: latestThread?.title,
                    launchSession: serverLaunchSession
                )
            )

            let sessionRows = sortedThreads.prefix(limit).compactMap { thread -> HomeDashboardRecentSession? in
                let project = shellSnapshot.projects.first(where: { $0.id == thread.projectId })
                let updatedAt = parseDate(thread.updatedAt)
                let launchSession = browserSession.withNavigation(
                    initialPath: dexThreadPath(environmentId: browserSession.environmentId, threadId: thread.id),
                    navigationTitle: thread.title
                )

                return HomeDashboardRecentSession(
                    key: ThreadKey(serverId: serverId, threadId: thread.id),
                    serverId: serverId,
                    serverDisplayName: browserSession.serverLabel,
                    sessionTitle: thread.title,
                    cwd: project?.workspaceRoot ?? "",
                    updatedAt: updatedAt,
                    hasTurnActive: isActiveTurnState(thread.latestTurn?.state),
                    launchSession: launchSession
                )
            }

            recentSessions.append(contentsOf: sessionRows)
        }

        return Snapshot(
            connectedServers: HomeDashboardSupport.mergeServers(native: [], dexCompanion: connectedServers),
            recentSessions: HomeDashboardSupport.mergeRecentSessions(
                native: [],
                dexCompanion: recentSessions,
                limit: limit
            )
        )
    }

    private static func dexServerId(for environmentId: String) -> String {
        "dex-companion:\(environmentId)"
    }

    private static func dexThreadPath(environmentId: String, threadId: String) -> String {
        "/_chat/\(environmentId)/\(threadId)"
    }

    private static func dexChatRootPath() -> String {
        "/_chat/"
    }

    private static func parseDate(_ value: String) -> Date {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        if let date = internetDateFormatter.date(from: value) {
            return date
        }
        return .distantPast
    }

    private static func isActiveTurnState(_ state: String?) -> Bool {
        guard let normalized = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }

        return normalized == "pending" || normalized == "in_progress" || normalized == "started"
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
