import Foundation
import Security
import Synchronization

/// Optional fields decode as nil from token JSON written before they existed (Keychain items).
public struct TokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    /// Consent time (Testing mode: the refresh token dies 7 days later). Set by `GoogleAuth.exchange`.
    public var consentedAt: Date?
    /// From `refresh_token_expires_in` when Google sends it.
    public var refreshTokenExpiresAt: Date?

    public init(accessToken: String, refreshToken: String, expiresAt: Date,
                consentedAt: Date? = nil, refreshTokenExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.consentedAt = consentedAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public protocol TokenStore: Sendable {
    func load() -> TokenSet?
    func save(_ tokens: TokenSet)
    func clear()
}

public final class MemoryTokenStore: TokenStore {
    private let tokens: Mutex<TokenSet?>

    public init(_ tokens: TokenSet? = nil) {
        self.tokens = Mutex(tokens)
    }

    public func load() -> TokenSet? { tokens.withLock { $0 } }
    public func save(_ tokens: TokenSet) { self.tokens.withLock { $0 = tokens } }
    public func clear() { tokens.withLock { $0 = nil } }
}

/// Stores the token set as a generic password in the login Keychain.
public final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    /// Keychain account holding the token of one Gmail account.
    public static func accountName(for email: String) -> String { "google-oauth:\(email.lowercased())" }

    public static func forAccount(_ email: String) -> KeychainTokenStore {
        KeychainTokenStore(account: accountName(for: email))
    }

    /// Where the single-account release kept its token.
    public static let legacyAccountName = "google-oauth"

    public init(service: String = "fi.mak8r.mail", account: String = "google-oauth") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> TokenSet? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
