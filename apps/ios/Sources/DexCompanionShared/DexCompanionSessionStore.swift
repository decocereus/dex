import Foundation

extension Notification.Name {
    static let dexDesktopSessionsDidChange = Notification.Name("dex.desktop.sessionsDidChange")
}

struct DexDesktopSavedSession: Codable, Equatable, Identifiable {
    let environmentId: String
    let serverLabel: String
    let httpBaseUrl: String
    let wsBaseUrl: String
    let sessionCookieName: String
    let createdAt: Date

    var id: String { environmentId }

    func makeBrowserSession() -> DexDesktopBrowserSession? {
        let token = (try? DexDesktopTokenStore.shared.load(environmentId: environmentId)) ?? nil
        guard let bearerToken = token,
              !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DexDesktopBrowserSession(
            environmentId: environmentId,
            serverLabel: serverLabel,
            httpBaseUrl: httpBaseUrl,
            wsBaseUrl: wsBaseUrl,
            bearerToken: bearerToken,
            sessionCookieName: sessionCookieName,
            initialPath: nil,
            navigationTitle: nil
        )
    }
}

enum DexDesktopSessionStore {
    private static let storageKey = "dex.desktop.sessions"
    private static let legacyStorageKey = "dex.companion.sessions"

    static func load() -> [DexDesktopSavedSession] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: storageKey) ?? defaults.data(forKey: legacyStorageKey),
              let sessions = try? JSONDecoder().decode([DexDesktopSavedSession].self, from: data) else {
            return []
        }

        if defaults.data(forKey: storageKey) == nil {
            defaults.set(data, forKey: storageKey)
        }

        return sessions.sorted { $0.serverLabel.localizedCaseInsensitiveCompare($1.serverLabel) == .orderedAscending }
    }

    static func save(_ sessions: [DexDesktopSavedSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: storageKey)
        defaults.removeObject(forKey: legacyStorageKey)
        NotificationCenter.default.post(name: .dexDesktopSessionsDidChange, object: nil)
    }

    static func upsert(_ session: DexDesktopSavedSession) {
        var sessions = load()
        sessions.removeAll { $0.environmentId == session.environmentId }
        sessions.append(session)
        save(sessions)
    }

    @discardableResult
    static func upsert(
        from session: DexDesktopBrowserSession,
        createdAt: Date = Date()
    ) -> DexDesktopSavedSession {
        let saved = DexDesktopSavedSession(
            environmentId: session.environmentId,
            serverLabel: session.serverLabel,
            httpBaseUrl: session.httpBaseUrl,
            wsBaseUrl: session.wsBaseUrl,
            sessionCookieName: session.sessionCookieName,
            createdAt: createdAt
        )
        upsert(saved)
        return saved
    }

    static func remove(environmentId: String) {
        var sessions = load()
        sessions.removeAll { $0.environmentId == environmentId }
        save(sessions)
        try? DexDesktopTokenStore.shared.delete(environmentId: environmentId)
    }
}

typealias DexCompanionSavedSession = DexDesktopSavedSession
typealias DexCompanionSessionStore = DexDesktopSessionStore
