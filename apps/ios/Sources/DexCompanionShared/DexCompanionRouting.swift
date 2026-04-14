import Foundation

@MainActor
enum DexCompanionRouting {
    static func serverId(for environmentId: String) -> String {
        "dex-companion:\(environmentId)"
    }

    static func environmentId(fromServerId serverId: String) -> String? {
        let prefix = "dex-companion:"
        guard serverId.hasPrefix(prefix) else { return nil }
        let environmentId = String(serverId.dropFirst(prefix.count))
        return environmentId.isEmpty ? nil : environmentId
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
