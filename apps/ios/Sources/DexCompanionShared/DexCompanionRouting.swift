import Foundation

@MainActor
enum DexCompanionRouting {
    static func serverId(for environmentId: String, projectId: String? = nil) -> String {
        if let projectId, !projectId.isEmpty {
            return "dex-companion:\(environmentId)::\(projectId)"
        }
        return "dex-companion:\(environmentId)"
    }

    static func environmentId(fromServerId serverId: String) -> String? {
        let prefix = "dex-companion:"
        guard serverId.hasPrefix(prefix) else { return nil }
        let remainder = String(serverId.dropFirst(prefix.count))
        let environmentId = remainder.components(separatedBy: "::").first ?? remainder
        return environmentId.isEmpty ? nil : environmentId
    }

    static func projectId(fromServerId serverId: String) -> String? {
        let prefix = "dex-companion:"
        guard serverId.hasPrefix(prefix) else { return nil }
        let remainder = String(serverId.dropFirst(prefix.count))
        let components = remainder.components(separatedBy: "::")
        guard components.count >= 2 else { return nil }
        let projectId = components[1]
        return projectId.isEmpty ? nil : projectId
    }

    static func threadPath(environmentId: String, threadId: String) -> String {
        "/_chat/\(environmentId)/\(threadId)"
    }

    static func chatRootPath() -> String {
        "/_chat/"
    }

    static func browserSession(forThreadKey key: ThreadKey) -> DexCompanionBrowserSession? {
        guard let environmentId = environmentId(fromServerId: key.serverId) else { return nil }
        return DexCompanionSessionStore.load()
            .first(where: { $0.environmentId == environmentId })?
            .makeBrowserSession()?
            .withNavigation(
                initialPath: threadPath(environmentId: environmentId, threadId: key.threadId),
                navigationTitle: nil
            )
    }

    static func browserSession(forServerId serverId: String) -> DexCompanionBrowserSession? {
        guard let environmentId = environmentId(fromServerId: serverId) else { return nil }
        return DexCompanionSessionStore.load()
            .first(where: { $0.environmentId == environmentId })?
            .makeBrowserSession()?
            .withNavigation(
                initialPath: chatRootPath(),
                navigationTitle: nil
            )
    }
}
