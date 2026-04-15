import Foundation

struct DexDesktopBrowserSession: Identifiable, Equatable, Hashable {
    let environmentId: String
    let serverLabel: String
    let httpBaseUrl: String
    let wsBaseUrl: String
    let bearerToken: String
    let sessionCookieName: String
    let initialPath: String?
    let navigationTitle: String?

    var id: String { environmentId }

    func withNavigation(
        initialPath: String?,
        navigationTitle: String? = nil
    ) -> DexDesktopBrowserSession {
        DexDesktopBrowserSession(
            environmentId: environmentId,
            serverLabel: serverLabel,
            httpBaseUrl: httpBaseUrl,
            wsBaseUrl: wsBaseUrl,
            bearerToken: bearerToken,
            sessionCookieName: sessionCookieName,
            initialPath: initialPath,
            navigationTitle: navigationTitle
        )
    }
}

enum DexDesktopPairingError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case pairingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Dex desktop payload did not include a valid endpoint."
        case .invalidResponse:
            return "Dex returned an invalid pairing response."
        case .pairingFailed(let message):
            return message
        }
    }
}

struct DexDesktopPairingClient {
    func redeem(_ payload: DexDesktopPairingPayload) async throws -> DexDesktopBrowserSession {
        guard let url = URL(string: payload.target.httpBaseUrl) else {
            throw DexDesktopPairingError.invalidEndpoint
        }
        let bootstrapUrl = url.appending(path: "api/auth/bootstrap/bearer")
        var request = URLRequest(url: bootstrapUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "credential": payload.pairing.credential,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DexDesktopPairingError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DexDesktopPairingError.pairingFailed(message ?? "Dex pairing failed.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["sessionToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DexDesktopPairingError.invalidResponse
        }

        try DexDesktopTokenStore.shared.save(token: token, environmentId: payload.environment.environmentId)

        return DexDesktopBrowserSession(
            environmentId: payload.environment.environmentId,
            serverLabel: payload.environment.label,
            httpBaseUrl: payload.target.httpBaseUrl,
            wsBaseUrl: payload.target.wsBaseUrl,
            bearerToken: token,
            sessionCookieName: payload.auth.sessionCookieName,
            initialPath: nil,
            navigationTitle: nil
        )
    }
}

typealias DexCompanionBrowserSession = DexDesktopBrowserSession
typealias DexCompanionPairingError = DexDesktopPairingError
typealias DexCompanionPairingClient = DexDesktopPairingClient
