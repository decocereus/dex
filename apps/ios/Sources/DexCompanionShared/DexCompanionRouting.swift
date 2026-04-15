import Foundation

enum DexCompanionRouting {
    private static let primaryPrefix = "dex-desktop:"
    private static let legacyPrefix = "dex-companion:"

    static func serverId(for environmentId: String, projectId: String? = nil) -> String {
        if let projectId, !projectId.isEmpty {
            return "\(primaryPrefix)\(environmentId)::\(projectId)"
        }
        return "\(primaryPrefix)\(environmentId)"
    }

    static func environmentId(fromServerId serverId: String) -> String? {
        guard let remainder = remainder(fromServerId: serverId) else { return nil }
        let environmentId = remainder.components(separatedBy: "::").first ?? remainder
        return environmentId.isEmpty ? nil : environmentId
    }

    static func projectId(fromServerId serverId: String) -> String? {
        guard let remainder = remainder(fromServerId: serverId) else { return nil }
        let components = remainder.components(separatedBy: "::")
        guard components.count >= 2 else { return nil }
        let projectId = components[1]
        return projectId.isEmpty ? nil : projectId
    }

    private static func remainder(fromServerId serverId: String) -> String? {
        if serverId.hasPrefix(primaryPrefix) {
            return String(serverId.dropFirst(primaryPrefix.count))
        }
        if serverId.hasPrefix(legacyPrefix) {
            return String(serverId.dropFirst(legacyPrefix.count))
        }
        return nil
    }

    static func threadPath(environmentId: String, threadId: String) -> String {
        "/_chat/\(environmentId)/\(threadId)"
    }

    static func chatRootPath() -> String {
        "/_chat/"
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
