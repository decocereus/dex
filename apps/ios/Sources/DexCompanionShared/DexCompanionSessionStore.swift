import Foundation

struct DexCompanionSavedSession: Codable, Equatable, Identifiable {
    let environmentId: String
    let serverLabel: String
    let httpBaseUrl: String
    let wsBaseUrl: String
    let sessionCookieName: String
    let createdAt: Date

    var id: String { environmentId }

    func makeBrowserSession() -> DexCompanionBrowserSession? {
        let token = (try? DexCompanionTokenStore.shared.load(environmentId: environmentId)) ?? nil
        guard let bearerToken = token,
              !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DexCompanionBrowserSession(
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

@MainActor
enum DexCompanionSessionStore {
    private static let storageKey = "dex.companion.sessions"

    static func load() -> [DexCompanionSavedSession] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let sessions = try? JSONDecoder().decode([DexCompanionSavedSession].self, from: data) else {
            return []
        }
        return sessions.sorted { $0.serverLabel.localizedCaseInsensitiveCompare($1.serverLabel) == .orderedAscending }
    }

    static func save(_ sessions: [DexCompanionSavedSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func upsert(_ session: DexCompanionSavedSession) {
        var sessions = load()
        sessions.removeAll { $0.environmentId == session.environmentId }
        sessions.append(session)
        save(sessions)
    }

    @discardableResult
    static func upsert(
        from session: DexCompanionBrowserSession,
        createdAt: Date = Date()
    ) -> DexCompanionSavedSession {
        let saved = DexCompanionSavedSession(
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
        try? DexCompanionTokenStore.shared.delete(environmentId: environmentId)
    }
}
