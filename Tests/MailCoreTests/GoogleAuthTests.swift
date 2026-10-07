import Foundation
import Testing
@testable import MailCore

@Suite struct PKCETests {
    @Test func rfc7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIsURLSafeAndLongEnough() {
        let v = PKCE.makeVerifier()
        #expect((43...128).contains(v.count))
        #expect(v.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
        #expect(PKCE.makeVerifier() != v)
    }
}

@Suite struct GoogleAuthTests {
    let config = OAuthConfig(clientID: "cid", clientSecret: "secret")
    let now = Date(timeIntervalSince1970: 1_000_000)

    func tokens(expiresIn: TimeInterval) -> TokenSet {
        TokenSet(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: now.addingTimeInterval(expiresIn))
    }

    @Test func authorizationURLHasRequiredParameters() async throws {
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: StubTransport { _ in (500, Data()) })
        let url = await auth.authorizationURL(redirectURI: "http://127.0.0.1:5555", state: "st", challenge: "ch")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["client_id"] == "cid")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555")
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "https://www.googleapis.com/auth/gmail.modify")
        #expect(items["code_challenge"] == "ch")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["state"] == "st")
    }

    @Test func exchangeStoresTokens() async throws {
        let store = MemoryTokenStore()
        let transport = StubTransport { _ in
            (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3599, "token_type": "Bearer"]))
        }
        let now = self.now
        let auth = GoogleAuth(config: config, store: store, transport: transport, now: { now })
        try await auth.exchange(code: "the-code", verifier: "ver", redirectURI: "http://127.0.0.1:1")
        // Phase 2: exchange stamps the consent time (Testing mode: the refresh token dies 7 days later).
        #expect(store.load() == TokenSet(accessToken: "a1", refreshToken: "r1", expiresAt: now.addingTimeInterval(3599),
                                         consentedAt: now, refreshTokenExpiresAt: nil))
        #expect(await auth.isSignedIn)
        let fields = formFields(transport.requests[0])
        #expect(transport.requests[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "the-code")
        #expect(fields["code_verifier"] == "ver")
        #expect(fields["client_secret"] == "secret")
    }

    @Test func notSignedInThrows() async {
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: StubTransport { _ in (500, Data()) })
        await #expect(throws: AuthError.notSignedIn) { try await auth.accessToken() }
    }

    @Test func validTokenIsReturnedWithoutNetwork() async throws {
        let transport = StubTransport { _ in (500, Data()) }
        let now = self.now
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(tokens(expiresIn: 600)), transport: transport, now: { now })
        #expect(try await auth.accessToken() == "old-access")
        #expect(transport.requests.isEmpty)
    }

    @Test func tokenNearExpiryIsRefreshedKeepingRefreshToken() async throws {
        let store = MemoryTokenStore(tokens(expiresIn: 30))
        let transport = StubTransport { _ in (200, json(["access_token": "new-access", "expires_in": 3600])) }
        let now = self.now
        let auth = GoogleAuth(config: config, store: store, transport: transport, now: { now })
        #expect(try await auth.accessToken() == "new-access")
        #expect(formFields(transport.requests[0])["grant_type"] == "refresh_token")
        #expect(formFields(transport.requests[0])["refresh_token"] == "refresh-1")
        #expect(store.load()?.refreshToken == "refresh-1")
    }

    @Test func invalidGrantClearsStore() async {
        let store = MemoryTokenStore(tokens(expiresIn: -10))
        let transport = StubTransport { _ in (400, json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."])) }
        let now = self.now
        let auth = GoogleAuth(config: config, store: store, transport: transport, now: { now })
        await #expect(throws: AuthError.invalidGrant) { try await auth.accessToken() }
        #expect(store.load() == nil)
        #expect(await auth.isSignedIn == false)
    }

    @Test func unauthorizedForcesRefresh() async throws {
        let transport = StubTransport { _ in (200, json(["access_token": "forced", "expires_in": 3600])) }
        let now = self.now
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(tokens(expiresIn: 600)), transport: transport, now: { now })
        #expect(try await auth.refreshAfterUnauthorized() == "forced")
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let counter = Counter()
        let transport = StubTransport { _ in
            counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return (200, json(["access_token": "shared", "expires_in": 3600]))
        }
        let now = self.now
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(tokens(expiresIn: -1)), transport: transport, now: { now })
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await auth.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results == Array(repeating: "shared", count: 5))
        #expect(counter.count == 1)
    }

    @Test func cancellingSignInStopsWaiting() async throws {
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: StubTransport { _ in (500, Data()) })
        let opened = Counter()
        let task = Task { try await auth.signIn(open: { _ in opened.increment() }) }
        while opened.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func mobileSignInExchangesCodeFromCallback() async throws {
        let transport = StubTransport { _ in (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3600])) }
        let mobile = OAuthConfig(clientID: "123-abc.apps.googleusercontent.com")
        let auth = GoogleAuth(config: mobile, store: MemoryTokenStore(), transport: transport)
        try await auth.signIn(redirectURI: mobile.mobileRedirectURI) { url in
            let state = GoogleAuth.callbackParameters(url)["state"] ?? ""
            return URL(string: "\(mobile.mobileRedirectURI)?state=\(state)&code=the-code&scope=x")!
        }
        #expect(await auth.isSignedIn)
        let fields = formFields(transport.requests[0])
        #expect(fields["code"] == "the-code")
        #expect(fields["redirect_uri"] == "com.googleusercontent.apps.123-abc:/oauth2redirect")
        #expect(fields["client_secret"] == nil)
    }

    @Test func mobileSignInRejectsWrongState() async {
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: StubTransport { _ in (500, Data()) })
        await #expect(throws: AuthError.stateMismatch) {
            try await auth.signIn(redirectURI: "x:/cb") { _ in URL(string: "x:/cb?state=other&code=c")! }
        }
    }

    @Test func mobileSignInReportsDenial() async {
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: StubTransport { _ in (500, Data()) })
        await #expect(throws: AuthError.denied("access_denied")) {
            try await auth.signIn(redirectURI: "x:/cb") { url in
                let state = GoogleAuth.callbackParameters(url)["state"] ?? ""
                return URL(string: "x:/cb?state=\(state)&error=access_denied")!
            }
        }
    }

    @Test func reversedClientIDScheme() {
        let config = OAuthConfig(clientID: "123-abc.apps.googleusercontent.com")
        #expect(config.reversedClientIDScheme == "com.googleusercontent.apps.123-abc")
        #expect(config.clientSecret.isEmpty)
    }

    @Test func currentTokensAfterExchange() async throws {
        let transport = StubTransport { _ in (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3600])) }
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: transport)
        #expect(await auth.currentTokens() == nil)
        try await auth.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        #expect(await auth.currentTokens()?.refreshToken == "r1")
    }

    // MARK: - Phase 2: token metadata, scope check, login hint (design phase2-daemon §4)

    @Test func exchangeParsesRefreshTokenExpiresIn() async throws {
        let store = MemoryTokenStore()
        let body = try Fixture.data("daemon_token_ok_expires_in")
        let now = self.now
        let auth = GoogleAuth(config: config, store: store, transport: StubTransport { _ in (200, body) }, now: { now })
        try await auth.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        let saved = try #require(store.load())
        #expect(saved.refreshToken == "1//test-refresh")
        #expect(saved.consentedAt == now)
        #expect(saved.refreshTokenExpiresAt == now.addingTimeInterval(604_799))
        #expect(await auth.currentTokens()?.refreshTokenExpiresAt == now.addingTimeInterval(604_799))
    }

    @Test func exchangeWithoutGrantedScopeIsDenied() async throws {
        let store = MemoryTokenStore()
        let transport = StubTransport { _ in
            (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3599,
                        "scope": "openid https://www.googleapis.com/auth/userinfo.email"]))
        }
        let auth = GoogleAuth(config: config, store: store, transport: transport)
        await #expect(throws: AuthError.denied("scope")) {
            try await auth.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        }
        #expect(store.load() == nil)
        #expect(await auth.isSignedIn == false)
    }

    @Test func exchangeAcceptsGrantedScopeAmongOthers() async throws {
        let transport = StubTransport { _ in
            (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3599,
                        "scope": "openid https://www.googleapis.com/auth/gmail.modify email"]))
        }
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: transport)
        try await auth.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        #expect(await auth.isSignedIn)
    }

    @Test func exchangeWithoutScopeFieldIsAccepted() async throws {
        let transport = StubTransport { _ in (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3599])) }
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: transport)
        try await auth.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        #expect(await auth.isSignedIn)
    }

    @Test func refreshCarriesConsentMetadata() async throws {
        let now = self.now
        let consented = now.addingTimeInterval(-86_400)
        let dies = consented.addingTimeInterval(604_799)
        let store = MemoryTokenStore(TokenSet(accessToken: "old", refreshToken: "refresh-1", expiresAt: now.addingTimeInterval(-1),
                                              consentedAt: consented, refreshTokenExpiresAt: dies))
        let transport = StubTransport { _ in (200, json(["access_token": "new-access", "expires_in": 3600])) }
        let auth = GoogleAuth(config: config, store: store, transport: transport, now: { now })
        #expect(try await auth.accessToken() == "new-access")
        let saved = try #require(store.load())
        #expect(saved.refreshToken == "refresh-1")
        #expect(saved.consentedAt == consented)
        #expect(saved.refreshTokenExpiresAt == dies)
    }

    @Test func clientSecretIsSentOnceOnRefresh() async throws {
        let store = MemoryTokenStore(tokens(expiresIn: -1))
        let transport = StubTransport { _ in (200, json(["access_token": "new", "expires_in": 3600])) }
        let now = self.now
        let auth = GoogleAuth(config: config, store: store, transport: transport, now: { now })
        _ = try await auth.accessToken()
        let body = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(body.components(separatedBy: "client_secret=").count - 1 == 1)          // V15
    }

    @Test func clientSecretIsSentOnceOnExchange() async throws {
        let transport = StubTransport { _ in (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3600])) }
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: transport)
        try await auth.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        let body = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(body.components(separatedBy: "client_secret=").count - 1 == 1)
    }

    @Test func invalidGrantFixtureIsInvalidGrant() async throws {
        let body = try Fixture.data("daemon_token_invalid_grant")
        let now = self.now
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(tokens(expiresIn: -10)),
                              transport: StubTransport { _ in (400, body) }, now: { now })
        await #expect(throws: AuthError.invalidGrant) { try await auth.accessToken() }
    }

    @Test func otherTokenErrorsAreBadResponse() async throws {
        let now = self.now
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(tokens(expiresIn: -10)),
                              transport: StubTransport { _ in (401, json(["error": "invalid_client"])) }, now: { now })
        await #expect(throws: AuthError.badResponse) { try await auth.accessToken() }
    }

    @Test func loginHintInAuthorizationURL() async throws {
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: StubTransport { _ in (500, Data()) })
        let url = await auth.authorizationURL(redirectURI: "http://127.0.0.1:5555", state: "st", challenge: "ch", loginHint: "matti@example.fi")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "login_hint" }?.value == "matti@example.fi")
        let plain = await auth.authorizationURL(redirectURI: "http://127.0.0.1:5555", state: "st", challenge: "ch")
        #expect(URLComponents(url: plain, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "login_hint" } == false)
    }

    @Test func signInPassesLoginHintToTheConsentURL() async throws {
        let transport = StubTransport { _ in (200, json(["access_token": "a1", "refresh_token": "r1", "expires_in": 3600])) }
        let auth = GoogleAuth(config: config, store: MemoryTokenStore(), transport: transport)
        try await auth.signIn(redirectURI: "http://127.0.0.1:53682", loginHint: "matti@example.fi") { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first { $0.name == "login_hint" }?.value == "matti@example.fi")
            let state = GoogleAuth.callbackParameters(url)["state"] ?? ""
            return URL(string: "http://127.0.0.1:53682/?state=\(state)&code=c1")!
        }
        #expect(await auth.isSignedIn)
        #expect(await auth.currentTokens()?.consentedAt != nil)
    }

    @Test func tokenSetDecodesWithoutPhase2Fields() throws {
        // Keychain JSON written by Phase 1 builds has no consentedAt / refreshTokenExpiresAt.
        let old = Data(#"{"accessToken":"a","refreshToken":"r","expiresAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(TokenSet.self, from: old)
        #expect(decoded.refreshToken == "r")
        #expect(decoded.consentedAt == nil)
        #expect(decoded.refreshTokenExpiresAt == nil)
    }

    @Test func signOutClears() async {
        let store = MemoryTokenStore(tokens(expiresIn: 600))
        let auth = GoogleAuth(config: config, store: store, transport: StubTransport { _ in (500, Data()) })
        await auth.signOut()
        #expect(store.load() == nil)
        #expect(await auth.isSignedIn == false)
    }
}

@Suite struct LoopbackReceiverTests {
    @Test func parsesCallbackRequestLine() {
        #expect(LoopbackReceiver.parseRequestLine("GET /?code=abc%2F1&state=xyz HTTP/1.1") == ["code": "abc/1", "state": "xyz"])
        #expect(LoopbackReceiver.parseRequestLine("GET /?error=access_denied&state=s HTTP/1.1") == ["error": "access_denied", "state": "s"])
        #expect(LoopbackReceiver.parseRequestLine("GET /favicon.ico HTTP/1.1") == nil)
        #expect(LoopbackReceiver.parseRequestLine("garbage") == nil)
    }

    @Test func receivesCallbackOverHTTP() async throws {
        let receiver = LoopbackReceiver()
        let port = try await receiver.start()
        #expect(port > 0)
        async let params = receiver.waitForCallback()
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=c1&state=s1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Mak8r Mail"))
        #expect(try await params == ["code": "c1", "state": "s1"])
        receiver.stop()
    }

    /// Phase 2 (§4): `start()` resumes on `.cancelled`, so a `stop()` that races the listener's
    /// readiness ends `start()` (with a port or an error) instead of hanging it. Either outcome passes;
    /// only a hang fails, and `valueWithin` turns a hang into a failure after 2 s.
    @MainActor
    @Test func stopBeforeReadyNeverHangsStart() async {
        for _ in 0..<20 {
            let receiver = LoopbackReceiver()
            let task = Task { () -> Bool in
                do {
                    _ = try await receiver.start()
                    return true
                } catch {
                    return false
                }
            }
            receiver.stop()
            _ = await valueWithin(task, "LoopbackReceiver.start after stop")
            receiver.stop()
        }
    }
}
