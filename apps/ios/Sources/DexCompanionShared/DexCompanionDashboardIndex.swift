import Foundation
import SwiftUI

@MainActor
enum DexCompanionDashboardIndex {
    struct Snapshot: Equatable {
        let connectedServers: [HomeDashboardServer]
        let recentSessions: [HomeDashboardRecentSession]
        let sessionSummaries: [AppSessionSummary]

        static let empty = Snapshot(
            connectedServers: [],
            recentSessions: [],
            sessionSummaries: []
        )
    }

    nonisolated static func makeSnapshot(
        savedSession: DexCompanionSavedSession,
        browserSession: DexCompanionBrowserSession,
        shellSnapshot: DexNativeShellSnapshot,
        limit: Int
    ) -> Snapshot {
        var connectedServers: [HomeDashboardServer] = []
        var recentSessions: [HomeDashboardRecentSession] = []
        var sessionSummaries: [AppSessionSummary] = []

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
                    statusLabel: "Paired",
                    statusColor: LitterTheme.accent,
                    workspaceRoot: project.workspaceRoot,
                    projectName: project.title,
                    latestThreadTitle: latestThread?.title
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
                hasTurnActive: thread.hasActiveTurn
            )
        }

        recentSessions.append(contentsOf: sessionRows)

        return Snapshot(
            connectedServers: connectedServers,
            recentSessions: recentSessions,
            sessionSummaries: sessionSummaries
        )
    }

    nonisolated static func mergeSnapshots(_ snapshots: [Snapshot], limit: Int) -> Snapshot {
        let connectedServers = snapshots.flatMap(\.connectedServers)
        let recentSessions = snapshots.flatMap(\.recentSessions)
        let sessionSummaries = snapshots.flatMap(\.sessionSummaries)

        return Snapshot(
            connectedServers: HomeDashboardSupport.mergeServers(
                native: [],
                dexCompanion: connectedServers
            ),
            recentSessions: HomeDashboardSupport.mergeRecentSessions(
                native: [],
                dexCompanion: recentSessions,
                limit: limit
            ),
            sessionSummaries: sessionSummaries.sorted { $0.updatedAtDate > $1.updatedAtDate }
        )
    }

    static func loadSnapshotsByEnvironment(limit: Int = 10) async -> [String: Snapshot] {
        let savedSessions = DexCompanionSessionStore.load()
        return await withTaskGroup(of: (String, Snapshot)?.self) { group in
            for savedSession in savedSessions {
                group.addTask {
                    guard let browserSession = savedSession.makeBrowserSession() else {
                        await MainActor.run {
                            DexCompanionSessionStore.remove(environmentId: savedSession.environmentId)
                        }
                        return nil
                    }

                    let client = DexCompanionClient(
                        httpBaseUrl: browserSession.httpBaseUrl,
                        bearerToken: browserSession.bearerToken
                    )

                    guard let shellSnapshot = try? await client.fetchNativeShellSnapshot() else {
                        return nil
                    }

                    return (
                        savedSession.environmentId,
                        makeSnapshot(
                            savedSession: savedSession,
                            browserSession: browserSession,
                            shellSnapshot: shellSnapshot,
                            limit: limit
                        )
                    )
                }
            }

            var results: [String: Snapshot] = [:]
            for await result in group {
                if let (environmentId, snapshot) = result {
                    results[environmentId] = snapshot
                }
            }
            return results
        }
    }

    static func load(limit: Int = 10) async -> Snapshot {
        let snapshotsByEnvironment = await loadSnapshotsByEnvironment(limit: limit)
        return mergeSnapshots(Array(snapshotsByEnvironment.values), limit: limit)
    }

    nonisolated private static func parseDate(_ value: String) -> Date {
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let internetDateFormatter = ISO8601DateFormatter()
        internetDateFormatter.formatOptions = [.withInternetDateTime]

        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        if let date = internetDateFormatter.date(from: value) {
            return date
        }
        return .distantPast
    }

    nonisolated private static func subagentStatus(from value: String?) -> AppSubagentStatus {
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

}
