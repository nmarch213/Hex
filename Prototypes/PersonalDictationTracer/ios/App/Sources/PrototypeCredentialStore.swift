import Foundation
import Security

enum PrototypeCredentialStore {
    private static let defaultService = "com.nmarch213.HexKeyboardTracer.prototype"
    private static let defaultAccount = "ronin-bearer-token"

    enum CredentialError: LocalizedError {
        case invalidTokenEncoding
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidTokenEncoding:
                "Hex could not decode the saved credential."
            case .keychain:
                "Hex could not access the saved credential."
            }
        }
    }

    static func loadToken(
        service: String = defaultService,
        account: String = defaultAccount
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status)
        }
        guard
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            throw CredentialError.invalidTokenEncoding
        }
        return token
    }

    static func saveToken(
        _ token: String,
        service: String = defaultService,
        account: String = defaultAccount
    ) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedToken.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychain(status)
            }
            return
        }

        guard let data = normalizedToken.data(using: .utf8) else {
            throw CredentialError.invalidTokenEncoding
        }
        let value: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, value as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialError.keychain(updateStatus)
        }

        let item = identity.merging(value) { _, newValue in newValue }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialError.keychain(addStatus)
        }
    }

    /// Moves the last legacy credential into the Keychain with one commit point.
    /// The legacy value remains recoverable until a Keychain upsert succeeds.
    static func loadAndMigrateLegacyToken(
        legacyToken: String,
        removeLegacyToken: () -> Void
    ) throws -> String? {
        try loadAndMigrateLegacyToken(
            legacyToken: legacyToken,
            loadKeychainToken: { try loadToken() },
            upsertKeychainToken: { try saveToken($0) },
            removeLegacyToken: removeLegacyToken
        )
    }

    static func loadAndMigrateLegacyToken(
        legacyToken: String,
        loadKeychainToken: () throws -> String?,
        upsertKeychainToken: (String) throws -> Void,
        removeLegacyToken: () -> Void
    ) throws -> String? {
        let loadedToken = try loadKeychainToken()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLegacyToken = legacyToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = loadedToken.flatMap { $0.isEmpty ? nil : $0 }
            ?? (normalizedLegacyToken.isEmpty ? nil : normalizedLegacyToken)
        guard let token else { return nil }

        try upsertKeychainToken(token)
        removeLegacyToken()
        return token
    }
}
