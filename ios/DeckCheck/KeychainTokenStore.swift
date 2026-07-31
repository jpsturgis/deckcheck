import Foundation
import Security
import DeckCheckCore

// Keychain persistence for the Google OAuth tokens. Tokens are the one
// genuinely secret thing the v2 flow holds, so they live in the Keychain — not
// UserDefaults (where v1's Apps Script shared-secret sits). Stored as a small JSON
// blob under one account so a refresh overwrites cleanly.

struct KeychainTokenStore {
    private let service: String
    private let account = "google-oauth"

    init(service: String = "com.example.DeckCheck.google") { self.service = service }

    private struct Blob: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var scope: String?
    }

    func save(_ token: OAuthToken) throws {
        let blob = Blob(accessToken: token.accessToken, refreshToken: token.refreshToken,
                        expiresAt: token.expiresAt, scope: token.scope)
        let data = try JSONEncoder().encode(blob)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attrs) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        }
    }

    func load() -> OAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return nil }
        return OAuthToken(accessToken: blob.accessToken, refreshToken: blob.refreshToken,
                          expiresAt: blob.expiresAt, scope: blob.scope)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case let .status(s): return "Keychain error \(s)."
            }
        }
    }
}
