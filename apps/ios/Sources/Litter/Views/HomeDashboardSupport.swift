import Foundation
import SwiftUI

struct HomeDashboardRecentSession: Identifiable, Hashable {
    let key: ThreadKey
    let serverId: String
    let serverDisplayName: String
    let sessionTitle: String
    let cwd: String
    let updatedAt: Date
    let hasTurnActive: Bool
    let launchSession: DexCompanionBrowserSession?

    var id: ThreadKey { key }

    var isDexCompanion: Bool {
        launchSession != nil
    }
}

struct HomeDashboardServer: Identifiable, Equatable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let isLocal: Bool
    let hasIpc: Bool
    let health: AppServerHealth
    let sourceLabel: String
    let statusLabel: String
    let statusColor: Color
    let projectName: String?
    let latestThreadTitle: String?
    let launchSession: DexCompanionBrowserSession?

    var deduplicationKey: String {
        if isLocal {
            return "local"
        }

        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
            .lowercased()

        return normalized.isEmpty ? id : normalized
    }

    static func == (lhs: HomeDashboardServer, rhs: HomeDashboardServer) -> Bool {
        lhs.id == rhs.id &&
            lhs.displayName == rhs.displayName &&
            lhs.host == rhs.host &&
            lhs.port == rhs.port &&
            lhs.isLocal == rhs.isLocal &&
            lhs.hasIpc == rhs.hasIpc &&
            lhs.health == rhs.health &&
            lhs.sourceLabel == rhs.sourceLabel &&
            lhs.statusLabel == rhs.statusLabel &&
            lhs.projectName == rhs.projectName &&
            lhs.latestThreadTitle == rhs.latestThreadTitle &&
            lhs.launchSession == rhs.launchSession
    }

    var isDexCompanion: Bool {
        launchSession != nil
    }
}

@MainActor
enum HomeDashboardSupport {
    static func recentConnectedSessions(
        from sessions: [AppSessionSummary],
        serversById: [String: HomeDashboardServer],
        limit: Int = 10
    ) -> [HomeDashboardRecentSession] {
        Array(
            sessions
                .filter { serversById[$0.key.serverId] != nil }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
                .compactMap { session in
                    guard let server = serversById[session.key.serverId] else { return nil }
                    return HomeDashboardRecentSession(
                        key: session.key,
                        serverId: session.key.serverId,
                        serverDisplayName: server.displayName,
                        sessionTitle: sessionTitle(for: session),
                        cwd: session.cwd,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(session.updatedAt ?? 0)),
                        hasTurnActive: session.hasActiveTurn,
                        launchSession: nil
                    )
                }
                .prefix(limit)
        )
    }

    static func sortedConnectedServers(
        from servers: [AppServerSnapshot],
        sessions: [AppSessionSummary] = [],
        activeServerId: String?
    ) -> [HomeDashboardServer] {
        var seenServerKeys: Set<String> = []
        let sessionsByServer = Dictionary(grouping: sessions) { $0.key.serverId }

        return servers
            .filter { $0.health != .disconnected || $0.connectionProgress != nil }
            .map { server in
                let recentSessions = (sessionsByServer[server.serverId] ?? [])
                    .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
                let primarySession = recentSessions.first
                let projectName = primarySession.flatMap { workspaceLabel(for: $0.cwd) }
                let latestThreadTitle = primarySession.map { sessionTitle(for: $0) }

                return HomeDashboardServer(
                    id: server.serverId,
                    displayName: server.displayName,
                    host: server.host,
                    port: server.port,
                    isLocal: server.isLocal,
                    hasIpc: server.hasIpc,
                    health: server.health,
                    sourceLabel: server.connectionModeLabel,
                    statusLabel: server.statusLabel,
                    statusColor: server.statusColor,
                    projectName: projectName,
                    latestThreadTitle: latestThreadTitle,
                    launchSession: nil
                )
            }
            .sorted { lhs, rhs in
                let lhsIsActive = lhs.id == activeServerId
                let rhsIsActive = rhs.id == activeServerId
                if lhsIsActive != rhsIsActive {
                    return lhsIsActive && !rhsIsActive
                }

                let byName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if byName != .orderedSame {
                    return byName == .orderedAscending
                }

                return lhs.id < rhs.id
            }
            .filter { server in
                seenServerKeys.insert(server.deduplicationKey).inserted
            }
    }

    static func serverSubtitle(for server: HomeDashboardServer) -> String {
        if let latestThreadTitle = server.latestThreadTitle,
           !latestThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return latestThreadTitle
        }

        if let projectName = server.projectName,
           !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return projectName
        }

        if server.isLocal {
            return "This iPhone"
        }

        return server.health == .connected ? "Ready to use" : server.statusLabel
    }

    static func workspaceLabel(for cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.isEmpty ? trimmed : lastPathComponent
    }

    static func mergeServers(
        native: [HomeDashboardServer],
        dexCompanion: [HomeDashboardServer]
    ) -> [HomeDashboardServer] {
        var seenKeys = Set<String>()
        return (native + dexCompanion).filter { server in
            seenKeys.insert(server.deduplicationKey).inserted
        }
    }

    static func mergeRecentSessions(
        native: [HomeDashboardRecentSession],
        dexCompanion: [HomeDashboardRecentSession],
        limit: Int = 10
    ) -> [HomeDashboardRecentSession] {
        var seen = Set<String>()
        return Array(
            (native + dexCompanion)
                .sorted { $0.updatedAt > $1.updatedAt }
                .filter { session in
                    let dedupeKey = "\(session.serverId)::\(session.key.threadId)"
                    return seen.insert(dedupeKey).inserted
                }
                .prefix(limit)
        )
    }

    private static func sessionTitle(for session: AppSessionSummary) -> String {
        session.displayTitle
    }
}
