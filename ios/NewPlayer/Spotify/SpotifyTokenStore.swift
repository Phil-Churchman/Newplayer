import Foundation
import Security

/// Where Spotify tokens live between launches.
protocol SpotifyTokenStoring {
    func load() -> SpotifyTokens?
    func save(_ tokens: SpotifyTokens)
    func clear()
}

/// Keychain-backed. Tokens grant access to an account's library, so they don't belong in
/// UserDefaults, which is plain plist in the app container.
struct SpotifyKeychainTokenStore: SpotifyTokenStoring {
    private let service = "com.example.newplayer.spotify"
    private let account = "tokens"

    private struct Stored: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var scopes: [String]?
    }

    func load() -> SpotifyTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return SpotifyTokens(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            expiresAt: stored.expiresAt,
            // Absent for tokens saved before scopes were recorded: treat those as granting
            // nothing, so they are re-authorized rather than trusted.
            scopes: Set(stored.scopes ?? [])
        )
    }

    func save(_ tokens: SpotifyTokens) {
        let stored = Stored(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            scopes: Array(tokens.scopes)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }

        clear()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
