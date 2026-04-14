import Foundation

struct MacBridgeLocalPairingStatus: Decodable {
    let ok: Bool
    let displayName: String
    let pairingMode: String
    let expiresAt: Int64
}

struct MacBridgePairingPayload: Codable, Equatable {
    let v: Int
    let relay: String
    let sessionId: String
    let macDeviceId: String
    let macIdentityPublicKey: String
    let expiresAt: Int64
}

private struct MacBridgePairingPayloadEnvelope: Decodable {
    let ok: Bool
    let payload: MacBridgePairingPayload
}

struct PairedMacRecord: Codable, Identifiable, Equatable {
    var id: String { macDeviceId }

    let displayName: String
    let host: String
    let relayURL: String
    let relaySessionId: String
    let macDeviceId: String
    let macIdentityPublicKey: String
    let trustedPhoneDeviceId: String?
    let trustedPhoneIdentityPublicKey: String?
    let pairedAt: Date
    let localPairingMode: String
}

enum PairedMacStore {
    private static let storageKey = "litter.pairedMacs"

    static func load() -> [PairedMacRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([PairedMacRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func save(_ records: [PairedMacRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func upsert(_ record: PairedMacRecord) {
        var records = load()
        records.removeAll { $0.macDeviceId == record.macDeviceId }
        records.append(record)
        save(records)
    }

    static func record(
        macDeviceId: String,
        macIdentityPublicKey: String? = nil
    ) -> PairedMacRecord? {
        load().last { record in
            guard record.macDeviceId == macDeviceId else { return false }
            guard let macIdentityPublicKey else { return true }
            return record.macIdentityPublicKey == macIdentityPublicKey
        }
    }

    static func hasTrustedPairing(
        macDeviceId: String,
        macIdentityPublicKey: String
    ) -> Bool {
        record(
            macDeviceId: macDeviceId,
            macIdentityPublicKey: macIdentityPublicKey
        ) != nil
    }
}

extension PairedMacRecord {
    func matchesCurrentPhoneIdentity(_ identity: AppPhoneIdentityRecord?) -> Bool {
        guard let identity else { return false }
        if let trustedPhoneDeviceId, !trustedPhoneDeviceId.isEmpty,
           let trustedPhoneIdentityPublicKey, !trustedPhoneIdentityPublicKey.isEmpty {
            return trustedPhoneDeviceId == identity.phoneDeviceId
                && trustedPhoneIdentityPublicKey == identity.phoneIdentityPublicKey
        }

        // Legacy records did not persist the phone identity. Treat them as
        // provisionally trusted and let the reconnect path recover if the Mac
        // rejects the signature because the phone identity changed later.
        return true
    }
}

enum MacPairingClientError: LocalizedError {
    case unsupportedServer
    case invalidResponse
    case pairingRequired
    case pairingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedServer:
            return "This Mac bridge did not advertise a compatible pairing endpoint."
        case .invalidResponse:
            return "The Mac bridge returned an invalid pairing response."
        case .pairingRequired:
            return "A pairing code is required for this Mac."
        case .pairingFailed(let message):
            return message
        }
    }
}

struct MacPairingClient {
    func requestPairingPayload(
        host: String,
        code: String,
        port: UInt16 = 56609
    ) async throws -> MacBridgePairingPayload {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = Int(port)
        components.path = "/v1/local/pairing/request"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = components.url else {
            throw MacPairingClientError.unsupportedServer
        }

        LLog.info(
            "pairing",
            "request local pairing payload manually",
            fields: [
                "host": host,
                "port": Int(port),
                "url": url.absoluteString
            ]
        )

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw MacPairingClientError.invalidResponse
        }
        if http.statusCode == 401 {
            throw MacPairingClientError.pairingRequired
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MacPairingClientError.pairingFailed(message ?? "Pairing failed.")
        }
        guard let decoded = try? JSONDecoder().decode(MacBridgePairingPayloadEnvelope.self, from: data),
              decoded.ok else {
            throw MacPairingClientError.invalidResponse
        }
        return decoded.payload
    }

    func fetchStatus(for server: DiscoveredServer) async throws -> MacBridgeLocalPairingStatus {
        let statusURL = try endpointURL(for: server, metadataKey: "status_path", defaultPath: "/v1/local/pairing/status")
        LLog.info(
            "pairing",
            "fetch local pairing status",
            fields: ["serverId": server.id, "host": server.hostname, "url": statusURL.absoluteString]
        )
        let (data, response) = try await URLSession.shared.data(from: statusURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            LLog.error(
                "pairing",
                "local pairing status invalid response",
                fields: [
                    "serverId": server.id,
                    "statusCode": (response as? HTTPURLResponse)?.statusCode ?? -1
                ]
            )
            throw MacPairingClientError.invalidResponse
        }
        guard let decoded = try? JSONDecoder().decode(MacBridgeLocalPairingStatus.self, from: data),
              decoded.ok else {
            LLog.error("pairing", "local pairing status decode failed", fields: ["serverId": server.id])
            throw MacPairingClientError.invalidResponse
        }
        LLog.info(
            "pairing",
            "local pairing status fetched",
            fields: [
                "serverId": server.id,
                "pairingMode": decoded.pairingMode,
                "expiresAt": decoded.expiresAt
            ]
        )
        return decoded
    }

    func requestPairingPayload(
        for server: DiscoveredServer,
        code: String? = nil
    ) async throws -> MacBridgePairingPayload {
        var components = URLComponents(
            url: try endpointURL(for: server, metadataKey: "pairing_path", defaultPath: "/v1/local/pairing/request"),
            resolvingAgainstBaseURL: false
        )
        let trimmedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCode.isEmpty {
            components?.queryItems = [URLQueryItem(name: "code", value: trimmedCode)]
        }
        guard let url = components?.url else {
            throw MacPairingClientError.unsupportedServer
        }
        LLog.info(
            "pairing",
            "request local pairing payload",
            fields: [
                "serverId": server.id,
                "host": server.hostname,
                "url": url.absoluteString,
                "hasCode": !trimmedCode.isEmpty
            ]
        )

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            LLog.error("pairing", "local pairing payload missing HTTP response", fields: ["serverId": server.id])
            throw MacPairingClientError.invalidResponse
        }

        if http.statusCode == 401 {
            LLog.warn("pairing", "local pairing payload requires code", fields: ["serverId": server.id])
            throw MacPairingClientError.pairingRequired
        }

        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            LLog.error(
                "pairing",
                "local pairing payload request failed",
                fields: [
                    "serverId": server.id,
                    "statusCode": http.statusCode,
                    "message": message ?? ""
                ]
            )
            throw MacPairingClientError.pairingFailed(message ?? "Pairing failed.")
        }

        guard let decoded = try? JSONDecoder().decode(MacBridgePairingPayloadEnvelope.self, from: data),
              decoded.ok else {
            LLog.error("pairing", "local pairing payload decode failed", fields: ["serverId": server.id])
            throw MacPairingClientError.invalidResponse
        }
        LLog.info(
            "pairing",
            "local pairing payload fetched",
            fields: [
                "serverId": server.id,
                "relay": decoded.payload.relay,
                "sessionId": decoded.payload.sessionId,
                "macDeviceId": decoded.payload.macDeviceId
            ]
        )
        return decoded.payload
    }

    private func endpointURL(
        for server: DiscoveredServer,
        metadataKey: String,
        defaultPath: String
    ) throws -> URL {
        guard server.isPairableMacBridge else {
            throw MacPairingClientError.unsupportedServer
        }
        let path = server.metadata[metadataKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = "http"
        components.host = server.hostname
        components.port = Int(server.port ?? 0)
        components.path = (path?.isEmpty == false ? path! : defaultPath)
        guard let url = components.url else {
            throw MacPairingClientError.unsupportedServer
        }
        return url
    }
}
