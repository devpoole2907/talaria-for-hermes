import Foundation
import Security

final class ServerProfileStore: Sendable {
    private static let service = "ai.talaria.client.ios"
    private static let accountPrefix = "profile."
    private static let fallbackFileName = "ServerProfiles.json"

    func loadAll() throws -> [ServerProfile] {
        var profilesByID: [UUID: ServerProfile] = [:]
        var firstError: Error?
        var completedQuery = false

        for profile in try loadFallbackProfiles() {
            profilesByID[profile.id] = profile
        }

        for useDataProtectionKeychain in [true, false] {
            do {
                for profile in try loadAll(useDataProtectionKeychain: useDataProtectionKeychain) {
                    profilesByID[profile.id] = profile
                }
                completedQuery = true
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if profilesByID.isEmpty, !completedQuery, let firstError {
            throw firstError
        }

        return profilesByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func save(_ profile: ServerProfile) throws {
        do {
            try save(profile, useDataProtectionKeychain: true)
        } catch {
            let dataProtectionError = error
            do {
                try save(profile, useDataProtectionKeychain: false)
            } catch {
                if dataProtectionError.isMissingKeychainEntitlement || error.isMissingKeychainEntitlement {
                    try saveFallbackProfile(profile)
                } else {
                    throw error
                }
            }
        }
    }

    func delete(_ profileID: UUID) throws {
        var firstError: Error?
        var completedDelete = false

        for useDataProtectionKeychain in [true, false] {
            do {
                try delete(profileID, useDataProtectionKeychain: useDataProtectionKeychain)
                completedDelete = true
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if !completedDelete, let firstError, !firstError.isMissingKeychainEntitlement {
            throw firstError
        }

        try deleteFallbackProfile(profileID)
    }

    private func loadAll(useDataProtectionKeychain: Bool) throws -> [ServerProfile] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

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

    private func save(_ profile: ServerProfile, useDataProtectionKeychain: Bool) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(profile)
        let account = Self.accountPrefix + profile.id.uuidString

        var baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtectionKeychain {
            baseQuery[kSecUseDataProtectionKeychain as String] = true
        }
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

    private func delete(_ profileID: UUID, useDataProtectionKeychain: Bool) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.accountPrefix + profileID.uuidString,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.statusFailure(status)
        }
    }

    // MARK: - Fallback storage

    private func loadFallbackProfiles() throws -> [ServerProfile] {
        let url = Self.fallbackFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ServerProfile].self, from: data)
    }

    private func saveFallbackProfile(_ profile: ServerProfile) throws {
        var profilesByID = Dictionary(uniqueKeysWithValues: (try loadFallbackProfiles()).map { ($0.id, $0) })
        profilesByID[profile.id] = profile
        try writeFallbackProfiles(Array(profilesByID.values))
    }

    private func deleteFallbackProfile(_ profileID: UUID) throws {
        var profiles = try loadFallbackProfiles()
        profiles.removeAll { $0.id == profileID }
        try writeFallbackProfiles(profiles)
    }

    private func writeFallbackProfiles(_ profiles: [ServerProfile]) throws {
        let url = Self.fallbackFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
        try data.write(to: url, options: [.atomic])
    }

    private static var fallbackFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Talaria")
            .appending(path: fallbackFileName)
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

private extension Error {
    var isMissingKeychainEntitlement: Bool {
        guard let error = self as? ServerProfileStore.KeychainError else { return false }
        switch error {
        case .statusFailure(let status):
            return status == errSecMissingEntitlement
        }
    }
}
