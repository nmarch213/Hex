import Foundation
import Security
@testable import HexKeyboardTracer
import XCTest

final class PrototypeCredentialStoreTests: XCTestCase {
    func testUpsertMigratesExistingItemToWhenUnlockedThisDeviceOnly() throws {
        let service = "com.nmarch213.HexKeyboardTracerTests.\(UUID().uuidString)"
        let account = "migration"
        let token = String(repeating: "a", count: 64)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { _ = SecItemDelete(identity as CFDictionary) }

        var legacyItem = identity
        legacyItem[kSecValueData as String] = Data(token.utf8)
        legacyItem[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(legacyItem as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement {
            throw XCTSkip(
                "The repository's unsigned Simulator test host has no Keychain entitlement."
            )
        }
        XCTAssertEqual(addStatus, errSecSuccess)

        XCTAssertEqual(
            try PrototypeCredentialStore.loadToken(
                service: service,
                account: account
            ),
            token
        )
        try PrototypeCredentialStore.saveToken(
            token,
            service: service,
            account: account
        )

        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        XCTAssertEqual(
            SecItemCopyMatching(query as CFDictionary, &result),
            errSecSuccess
        )
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    func testLegacyCredentialRemainsWhenKeychainReadFails() {
        var removedLegacyCredential = false

        XCTAssertThrowsError(
            try PrototypeCredentialStore.loadAndMigrateLegacyToken(
                legacyToken: String(repeating: "a", count: 64),
                loadKeychainToken: { throw TestFailure.keychainRead },
                upsertKeychainToken: { _ in
                    XCTFail("A failed Keychain read must not attempt an upsert")
                },
                removeLegacyToken: { removedLegacyCredential = true }
            )
        ) { error in
            XCTAssertEqual(error as? TestFailure, .keychainRead)
        }
        XCTAssertFalse(removedLegacyCredential)
    }

    func testLegacyCredentialRemainsWhenKeychainUpsertFails() {
        var removedLegacyCredential = false
        let keychainToken = String(repeating: "d", count: 64)

        XCTAssertThrowsError(
            try PrototypeCredentialStore.loadAndMigrateLegacyToken(
                legacyToken: String(repeating: "b", count: 64),
                loadKeychainToken: { keychainToken },
                upsertKeychainToken: { token in
                    XCTAssertEqual(token, keychainToken)
                    throw TestFailure.keychainUpsert
                },
                removeLegacyToken: { removedLegacyCredential = true }
            )
        ) { error in
            XCTAssertEqual(error as? TestFailure, .keychainUpsert)
        }
        XCTAssertFalse(removedLegacyCredential)
    }

    func testLegacyCredentialIsRemovedAfterSuccessfulKeychainUpsert() throws {
        let legacyToken = String(repeating: "c", count: 64)
        var events: [String] = []

        let loadedToken = try PrototypeCredentialStore.loadAndMigrateLegacyToken(
            legacyToken: legacyToken,
            loadKeychainToken: { nil },
            upsertKeychainToken: { token in
                XCTAssertEqual(token, legacyToken)
                events.append("upsert")
            },
            removeLegacyToken: { events.append("remove legacy") }
        )

        XCTAssertEqual(loadedToken, legacyToken)
        XCTAssertEqual(events, ["upsert", "remove legacy"])
    }
}

private enum TestFailure: Error, Equatable {
    case keychainRead
    case keychainUpsert
}
