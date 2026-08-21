import Foundation
import Security

enum PrototypeCredentialStore {
    private static let service = "com.nmarch213.HexKeyboardTracer.prototype"
    private static let account = "ronin-bearer-token"

    static func loadToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return token
    }

    static func saveToken(_ token: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)

        guard !token.isEmpty, let data = token.data(using: .utf8) else { return }
        let item: [String: Any] = identity.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, newValue in newValue }
        SecItemAdd(item as CFDictionary, nil)
    }
}
