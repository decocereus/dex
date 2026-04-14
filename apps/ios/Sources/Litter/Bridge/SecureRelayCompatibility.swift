import Foundation

struct AppPhoneIdentityRecord: Equatable, Sendable {
    let phoneDeviceId: String
    let phoneIdentityPublicKey: String
}

struct AppSecureApplicationPayloadRecord: Equatable, Sendable {
    let bridgeOutboundSeq: UInt64?
    let payloadText: String
}

enum SecureRelayCompatibilityError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Legacy paired-Mac secure relay is not available in this Dex-integrated build yet. Use the Dex companion QR flow instead."
    }
}

final class SecureRelayBridgeClient {
    init(identityPath: String?) {}

    func phoneIdentity() throws -> AppPhoneIdentityRecord {
        throw SecureRelayCompatibilityError.unavailable
    }
}

final class SecureRelayProxyBridge {
    init() {}

    func startPairedMacProxy(
        relayUrl: String,
        relaySessionId: String,
        macDeviceId: String,
        macIdentityPublicKey: String,
        trustedReconnect: Bool
    ) async throws -> String {
        throw SecureRelayCompatibilityError.unavailable
    }

    func stop() async {}

    func activeLocalUrl() throws -> String? {
        nil
    }
}
