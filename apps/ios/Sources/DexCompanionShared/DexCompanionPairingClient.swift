import Foundation

struct DexCompanionBrowserSession: Identifiable, Equatable, Hashable {
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
    ) -> DexCompanionBrowserSession {
        DexCompanionBrowserSession(
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

enum DexCompanionPairingError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case pairingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Dex companion payload did not include a valid endpoint."
        case .invalidResponse:
            return "Dex returned an invalid pairing response."
        case .pairingFailed(let message):
            return message
        }
    }
}

struct DexCompanionPairingClient {
    func redeem(_ payload: DexCompanionPairingPayload) async throws -> DexCompanionBrowserSession {
        guard let url = URL(string: payload.target.httpBaseUrl) else {
            throw DexCompanionPairingError.invalidEndpoint
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
            throw DexCompanionPairingError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DexCompanionPairingError.pairingFailed(message ?? "Dex pairing failed.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["sessionToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DexCompanionPairingError.invalidResponse
        }

        try DexCompanionTokenStore.shared.save(token: token, environmentId: payload.environment.environmentId)

        return DexCompanionBrowserSession(
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
