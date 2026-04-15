import Foundation
import Security

final class DexCompanionTokenStore {
    static let shared = DexCompanionTokenStore()

    private let service = "com.dex.ios.desktop.session"
    private let legacyService = "com.dex.ios.companion.session"

    private init() {}

    func load(environmentId: String) throws -> String? {
        if let token = try load(environmentId: environmentId, service: service) {
            return token
        }
        let legacyToken = try load(environmentId: environmentId, service: legacyService)
        if let legacyToken {
            try? save(token: legacyToken, environmentId: environmentId)
        }
        return legacyToken
    }

    func save(token: String, environmentId: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = baseQuery(environmentId: environmentId).merging([
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]) { _, new in new }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(baseQuery(environmentId: environmentId) as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(updateStatus))"])
            }
            return
        }

        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(status))"])
        }
    }

    func delete(environmentId: String) throws {
        try delete(environmentId: environmentId, service: service)
        try delete(environmentId: environmentId, service: legacyService)
    }

    private func baseQuery(environmentId: String) -> [String: Any] {
        baseQuery(environmentId: environmentId, service: service)
    }

    private func baseQuery(environmentId: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentId,
        ]
    }

    private func load(environmentId: String, service: String) throws -> String? {
        let query = baseQuery(environmentId: environmentId, service: service).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(status))"])
        }
    }

    private func delete(environmentId: String, service: String) throws {
        let status = SecItemDelete(baseQuery(environmentId: environmentId, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(status))"])
        }
    }
}
