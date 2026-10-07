import Foundation
import os

private let authLog = Logger(subsystem: "fi.mak8r.mail", category: "auth")

public struct OAuthConfig: Sendable, Equatable {
    public var clientID: String
    /// Empty for an iOS client, which has no secret.
    public var clientSecret: String

    public init(clientID: String, clientSecret: String = "") {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// The custom URL scheme Google gives an iOS client: the client ID reversed,
    /// `com.googleusercontent.apps.<prefix>` for `<prefix>.apps.googleusercontent.com`.
    public var reversedClientIDScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    /// Redirect URI of the iOS flow; Google accepts any path under the reversed client ID scheme.
    public var mobileRedirectURI: String { "\(reversedClientIDScheme):/oauth2redirect" }

    /// Reads credentials injected into Info.plist by `make app`, falling back to environment variables.
    /// The secret is optional: the iOS app uses an iOS client, which has none.
    public static func fromBundle(_ bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> OAuthConfig? {
        func value(_ plistKey: String, _ envKey: String) -> String? {
            let v = (bundle.object(forInfoDictionaryKey: plistKey) as? String) ?? environment[envKey]
            guard let v, !v.isEmpty, !v.hasPrefix("__") else { return environment[envKey] }
            return v
        }
        guard let id = value("GoogleClientID", "MAK8R_GOOGLE_CLIENT_ID") else { return nil }
        return OAuthConfig(clientID: id, clientSecret: value("GoogleClientSecret", "MAK8R_GOOGLE_CLIENT_SECRET") ?? "")
    }
}

public enum AuthError: Error, Equatable, Sendable {
    case notSignedIn
    case invalidGrant
    case stateMismatch
    case denied(String)
    case badResponse
}

public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    func refreshAfterUnauthorized() async throws -> String
}

public actor GoogleAuth: AccessTokenProvider {
    public static let scope = "https://www.googleapis.com/auth/gmail.modify"
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private let config: OAuthConfig
    private let store: TokenStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var tokens: TokenSet?
    private var refreshTask: Task<TokenSet, Error>?

    public init(config: OAuthConfig, store: TokenStore, transport: HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.store = store
        self.transport = transport
        self.now = now
        self.tokens = store.load()
    }

    public var isSignedIn: Bool { tokens != nil }

    /// Tokens after a sign-in, for moving them into the account's own store.
    public func currentTokens() -> TokenSet? { tokens }

    /// `loginHint` preselects the account on Google's consent page (`login_hint`).
    public func authorizationURL(redirectURI: String, state: String, challenge: String, loginHint: String? = nil) -> URL {
        var c = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        c.queryItems = items
        return c.url!
    }

    /// Runs the full desktop flow: loopback listener, browser consent, code exchange.
    public func signIn(open: @Sendable (URL) async -> Void) async throws {
        let receiver = LoopbackReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        let redirectURI = "http://127.0.0.1:\(port)"
        await open(authorizationURL(redirectURI: redirectURI, state: state, challenge: PKCE.challenge(for: verifier)))
        let params = try await withTaskCancellationHandler {
            try await receiver.waitForCallback()
        } onCancel: {
            receiver.stop()
        }
        try await finishSignIn(params, state: state, verifier: verifier, redirectURI: redirectURI)
    }

    /// Runs the mobile flow: `authorize` shows the consent page (ASWebAuthenticationSession on iOS)
    /// and returns the URL Google redirected to, which carries the code.
    /// Also the daemon's CLI login: `authorize` races the loopback callback and a pasted redirect URL.
    public func signIn(redirectURI: String, loginHint: String? = nil,
                       authorize: @Sendable (URL) async throws -> URL) async throws {
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        let url = authorizationURL(redirectURI: redirectURI, state: state, challenge: PKCE.challenge(for: verifier),
                                   loginHint: loginHint)
        let callback = try await authorize(url)
        try await finishSignIn(Self.callbackParameters(callback), state: state, verifier: verifier, redirectURI: redirectURI)
    }

    /// Query parameters of a redirect URL, e.g. `scheme:/oauth2redirect?state=…&code=…`.
    public static func callbackParameters(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func finishSignIn(_ params: [String: String], state: String, verifier: String, redirectURI: String) async throws {
        guard params["state"] == state else { throw AuthError.stateMismatch }
        if let error = params["error"] { throw AuthError.denied(error) }
        guard let code = params["code"] else { throw AuthError.badResponse }
        try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
    }

    public func exchange(code: String, verifier: String, redirectURI: String) async throws {
        let response = try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("client_id", config.clientID),
        ])
        guard let refresh = response.refresh_token else { throw AuthError.badResponse }
        // Google reports the granted scopes; a user who unticked Gmail on the consent page gets none.
        if let granted = response.scope, !granted.split(separator: " ").contains(Substring(Self.scope)) {
            throw AuthError.denied("scope")
        }
        let stamp = now()
        let set = TokenSet(accessToken: response.access_token, refreshToken: refresh,
                           expiresAt: stamp.addingTimeInterval(TimeInterval(response.expires_in ?? 3600)),
                           consentedAt: stamp,
                           refreshTokenExpiresAt: response.refresh_token_expires_in.map { stamp.addingTimeInterval(TimeInterval($0)) })
        tokens = set
        store.save(set)
    }

    public func accessToken() async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        if tokens.expiresAt.timeIntervalSince(now()) > 60 { return tokens.accessToken }
        return try await refreshed().accessToken
    }

    public func refreshAfterUnauthorized() async throws -> String {
        guard tokens != nil else { throw AuthError.notSignedIn }
        return try await refreshed().accessToken
    }

    public func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        store.clear()
    }

    private func refreshed() async throws -> TokenSet {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw AuthError.notSignedIn }
        let task = Task { try await self.performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: TokenSet) async throws -> TokenSet {
        do {
            let response = try await tokenRequest([
                ("grant_type", "refresh_token"),
                ("refresh_token", current.refreshToken),
                ("client_id", config.clientID),
            ])
            let set = TokenSet(accessToken: response.access_token,
                               refreshToken: response.refresh_token ?? current.refreshToken,
                               expiresAt: now().addingTimeInterval(TimeInterval(response.expires_in ?? 3600)),
                               consentedAt: current.consentedAt,
                               refreshTokenExpiresAt: current.refreshTokenExpiresAt)
            tokens = set
            store.save(set)
            return set
        } catch AuthError.invalidGrant {
            tokens = nil
            store.clear()
            throw AuthError.invalidGrant
        }
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Int?
        var refresh_token_expires_in: Int?
        var scope: String?
    }

    private struct ErrorResponse: Decodable {
        var error: String
    }

    private func tokenRequest(_ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // An iOS client has no secret; Google rejects an empty one.
        let secret = config.clientSecret.isEmpty ? [] : [("client_secret", config.clientSecret)]
        request.httpBody = FormEncoding.encode(fields + secret)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let error = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            if error == "invalid_grant" { throw AuthError.invalidGrant }
            // Status and Google's error code only; the body can echo request fields.
            authLog.error("token endpoint HTTP \(response.statusCode, privacy: .public) error=\(error ?? "-", privacy: .public)")
            throw AuthError.badResponse
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw AuthError.badResponse }
        return decoded
    }
}
