import Foundation
import Security

final class ServerProfileStore: Sendable {
    private static let service = "ai.talaria.client.ios"
    private static let accountPrefix = "profile."

    func loadAll() throws -> [ServerProfile] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        query[kSecUseDataProtectionKeychain as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let entries = item as? [[String: Any]] else {
            throw KeychainError.statusFailure(status)
        }

        let decoder = JSONDecoder()
        var profiles: [ServerProfile] = []
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix(Self.accountPrefix),
                  let data = entry[kSecValueData as String] as? Data,
                  let profile = try? decoder.decode(ServerProfile.self, from: data)
            else { continue }
            profiles.append(profile)
        }
        return profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ profile: ServerProfile) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(profile)
        let account = Self.accountPrefix + profile.id.uuidString

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: profile.name,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            for (key, value) in attributes { addQuery[key] = value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.statusFailure(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.statusFailure(status)
        }
    }

    func delete(_ profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.accountPrefix + profileID.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.statusFailure(status)
        }
    }

    enum KeychainError: Error, LocalizedError {
        case statusFailure(OSStatus)

        var errorDescription: String? {
            switch self {
            case .statusFailure(let status):
                "Keychain error (status \(status))."
            }
        }
    }
}
