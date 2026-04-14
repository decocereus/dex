import Foundation
import SwiftUI

@MainActor
enum DexCompanionDashboardIndex {
    struct Snapshot: Equatable {
        let connectedServers: [HomeDashboardServer]
        let recentSessions: [HomeDashboardRecentSession]
        let sessionSummaries: [AppSessionSummary]
        let launchSessionByThreadKey: [ThreadKey: DexCompanionBrowserSession]
        let launchSessionByServerId: [String: DexCompanionBrowserSession]
    }

    static func load(limit: Int = 10) async -> Snapshot {
        let savedSessions = DexCompanionSessionStore.load()
        var connectedServers: [HomeDashboardServer] = []
        var recentSessions: [HomeDashboardRecentSession] = []
        var sessionSummaries: [AppSessionSummary] = []
        var launchSessionByThreadKey: [ThreadKey: DexCompanionBrowserSession] = [:]
        var launchSessionByServerId: [String: DexCompanionBrowserSession] = [:]

        for savedSession in savedSessions {
            guard let browserSession = savedSession.makeBrowserSession() else {
                DexCompanionSessionStore.remove(environmentId: savedSession.environmentId)
                continue
            }

            let client = DexCompanionClient(
                httpBaseUrl: browserSession.httpBaseUrl,
                bearerToken: browserSession.bearerToken
            )

            guard let shellSnapshot = try? await client.fetchNativeShellSnapshot() else {
                continue
            }

            let host = URL(string: browserSession.httpBaseUrl)?.host ?? "dex"
            let port = UInt16(URL(string: browserSession.httpBaseUrl)?.port ?? 443)
            let sortedThreads = shellSnapshot.sessionSummaries.sorted {
                parseDate($0.updatedAt) > parseDate($1.updatedAt)
            }
            for project in shellSnapshot.projects {
                let serverId = DexCompanionRouting.serverId(
                    for: savedSession.environmentId,
                    projectId: project.id
                )
                let latestThread = sortedThreads.first(where: { $0.projectId == project.id })
                let serverLaunchSession = browserSession.withNavigation(
                    initialPath: DexCompanionRouting.chatRootPath(),
                    navigationTitle: project.title
                )
                launchSessionByServerId[serverId] = serverLaunchSession

                connectedServers.append(
                    HomeDashboardServer(
                        id: serverId,
                        displayName: project.title,
                        host: host,
                        port: port,
                        isLocal: false,
                        hasIpc: false,
                        health: .connected,
                        sourceLabel: browserSession.serverLabel,
                        statusLabel: "Connected",
                        statusColor: LitterTheme.accent,
                        projectName: project.title,
                        latestThreadTitle: latestThread?.title,
                        launchSession: serverLaunchSession
                    )
                )
            }

            let sessionRows = sortedThreads.prefix(limit).compactMap { thread -> HomeDashboardRecentSession? in
                let project = shellSnapshot.projects.first(where: { $0.id == thread.projectId })
                let updatedAt = parseDate(thread.updatedAt)
                let serverId = DexCompanionRouting.serverId(
                    for: savedSession.environmentId,
                    projectId: thread.projectId
                )
                let threadKey = ThreadKey(serverId: serverId, threadId: thread.threadRef.threadId)
                let launchSession = browserSession.withNavigation(
                    initialPath: DexCompanionRouting.threadPath(
                        environmentId: browserSession.environmentId,
                        threadId: thread.threadRef.threadId
                    ),
                    navigationTitle: thread.title
                )
                launchSessionByThreadKey[threadKey] = launchSession

                sessionSummaries.append(
                    AppSessionSummary(
                        key: threadKey,
                        serverDisplayName: project?.title ?? browserSession.serverLabel,
                        serverHost: host,
                        title: thread.title,
                        preview: thread.preview,
                        cwd: thread.cwd ?? project?.workspaceRoot ?? "",
                        model: thread.model,
                        modelProvider: thread.modelProvider,
                        parentThreadId: thread.parentThreadId,
                        agentNickname: thread.agentNickname,
                        agentRole: thread.agentRole,
                        agentDisplayLabel: thread.agentDisplayLabel,
                        agentStatus: subagentStatus(from: thread.agentStatus),
                        updatedAt: Int64(updatedAt.timeIntervalSince1970),
                        hasActiveTurn: thread.hasActiveTurn,
                        isSubagent: thread.isSubagent,
                        isFork: thread.isFork
                    )
                )

                return HomeDashboardRecentSession(
                    key: threadKey,
                    serverId: serverId,
                    serverDisplayName: project?.title ?? browserSession.serverLabel,
                    sessionTitle: thread.title,
                    cwd: thread.cwd ?? project?.workspaceRoot ?? "",
                    updatedAt: updatedAt,
                    hasTurnActive: thread.hasActiveTurn,
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
            ),
            sessionSummaries: sessionSummaries.sorted { $0.updatedAtDate > $1.updatedAtDate },
            launchSessionByThreadKey: launchSessionByThreadKey,
            launchSessionByServerId: launchSessionByServerId
        )
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

    private static func subagentStatus(from value: String?) -> AppSubagentStatus {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pendinginit":
            return .pendingInit
        case "running":
            return .running
        case "interrupted":
            return .interrupted
        case "completed":
            return .completed
        case "errored", "error":
            return .errored
        case "shutdown", "stopped":
            return .shutdown
        default:
            return .unknown
        }
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
