import Darwin
import Foundation
import MailCore

/// `daemon/login-pending.json`: what `login --callback` needs to find the waiting `login`. No secrets:
/// the code it forwards is single-use and worthless without the PKCE verifier, which never leaves the
/// waiting process.
public struct LoginPending: Codable, Sendable, Equatable {
    public var port: UInt16
    public var pid: Int32
    public var email: String
    public var createdAt: Date
    /// No loopback listener (paste-only mode): the URL can only be pasted into the waiting login's own window.
    public var pasteOnly = false

    public init(port: UInt16, pid: Int32, email: String, createdAt: Date, pasteOnly: Bool = false) {
        self.port = port
        self.pid = pid
        self.email = email
        self.createdAt = createdAt
        self.pasteOnly = pasteOnly
    }

    private enum CodingKeys: String, CodingKey { case port, pid, email, createdAt, pasteOnly }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(UInt16.self, forKey: .port)
        pid = try c.decode(Int32.self, forKey: .pid)
        email = try c.decode(String.self, forKey: .email)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        pasteOnly = try c.decodeIfPresent(Bool.self, forKey: .pasteOnly) ?? false
    }

    /// Whether process `pid` exists (EPERM: it exists under another user).
    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func read(_ url: URL) -> LoginPending? {
        guard let data = try? AtomicFile.read(url) else { return nil }
        return try? DaemonJSON.decoder().decode(LoginPending.self, from: data)
    }

    public func write(to url: URL) throws {
        try AtomicFile.ensureDirectory(url.deletingLastPathComponent(), mode: 0o700)
        try AtomicFile.write(try DaemonJSON.encoder().encode(self), to: url, mode: 0o600)
    }
}

public enum LoginError: Error, Equatable, Sendable {
    /// No OAuth client in the binary (`make daemon`).
    case oauthMissing
    case invalidEmail(String)
    /// Signed in with another account; nothing was stored.
    case wrongAccount(signedIn: String, expected: String)
    /// Consent refused, the Gmail scope unticked, or a state mismatch.
    case denied(String)
    /// No callback within the overall timeout.
    case timeout
    /// The token endpoint or the profile lookup failed.
    case unavailable(String)
    // login --callback
    case noPendingLogin
    case pendingExpired
    case invalidCallback(String)
    case forwardFailed(String)
    case pasteOnlyLogin
    case anotherLoginPending(String)

    /// The CLI's exit code (design §15).
    public var exitCode: Int32 {
        switch self {
        case .invalidEmail, .invalidCallback: 64
        case .oauthMissing, .timeout, .unavailable, .noPendingLogin, .pendingExpired, .forwardFailed, .pasteOnlyLogin,
             .anotherLoginPending: 69
        case .wrongAccount, .denied: 77
        }
    }

    /// What the CLI prints (Finnish; never a token, code or the consent URL).
    public var message: String {
        switch self {
        case .oauthMissing:
            "OAuth-asiakas puuttuu: aja make daemon"
        case .invalidEmail(let text):
            "Virheellinen sähköpostiosoite: \(text)"
        case .wrongAccount(let signedIn, let expected):
            "Kirjauduit tilillä \(signedIn), odotettiin \(expected). Mitään ei tallennettu."
        case .denied("scope"):
            "Gmail-oikeutta ei myönnetty (valintaruutu jäi tyhjäksi). Kirjaudu uudelleen ja salli Gmail. Mitään ei tallennettu."
        case .denied("state"):
            "Paluuosoite ei kuulu tähän kirjautumiseen (state ei täsmää). Mitään ei tallennettu."
        case .denied(let what):
            "Kirjautuminen hylättiin (\(what)). Mitään ei tallennettu."
        case .timeout:
            "Aikakatkaisu: kirjautuminen ei valmistunut 10 minuutissa. Mitään ei tallennettu."
        case .unavailable(let what):
            "Kirjautuminen epäonnistui (\(what)). Tarkista verkkoyhteys ja yritä uudelleen."
        case .noPendingLogin:
            "Mikään kirjautuminen ei odota: aja ensin mak8r-daemon login <osoite> --no-browser."
        case .pendingExpired:
            "Odottava kirjautuminen on yli 10 minuuttia vanha: aloita uudelleen."
        case .invalidCallback(let why):
            "Osoite ei kelpaa: \(why)."
        case .forwardFailed(let why):
            "Välitys odottavalle kirjautumiselle epäonnistui: \(why)"
        case .pasteOnlyLogin:
            "Odottava kirjautuminen ei kuuntele paluuosoitetta (vain liittäminen): liitä osoite sen omaan ikkunaan."
        case .anotherLoginPending(let email):
            "Toinen kirjautuminen (\(email)) odottaa jo: vie se loppuun tai keskeytä se ensin."
        }
    }
}

/// The receiving end of the loopback redirect. `LoopbackReceiver` in production; tests pass a fake.
public protocol LoopbackSource: Sendable {
    func start() async throws -> UInt16
    func waitForCallback() async throws -> [String: String]
    func stop()
}

extension LoopbackReceiver: LoopbackSource {}

/// `mak8r-daemon login <email>` (design §8.2): loopback receiver, plus a pasted redirect URL on stdin,
/// plus `login --callback` from another shell (phone consent). Checks the profile address, never revokes,
/// and writes only the daemon's token file. The CLI owns the Finnish text and the browser.
public enum LoginFlow {
    /// Redirect URI in paste-only mode: Google accepts any loopback port for a desktop client.
    public static let pasteOnlyRedirect = "http://127.0.0.1:53682"
    public static let startTimeout: TimeInterval = 5
    public static let overallTimeout: TimeInterval = 600
    /// `login --callback` accepts a pending login at most this old.
    public static let pendingMaxAge: TimeInterval = 600

    public struct Environment: Sendable {
        public var paths: DaemonPaths
        public var oauth: OAuthConfig?
        public var clock: any DaemonClock
        /// Token endpoint and the profile lookup.
        public var transport: any HTTPTransport
        public var makeReceiver: @Sendable () -> any LoopbackSource
        /// Shows the consent URL (stdout, never the log), opens the browser unless `--no-browser`, and
        /// prints the remote instructions. `pasteOnly`: no listener is running.
        public var present: @Sendable (_ url: URL, _ pasteOnly: Bool) -> Void
        /// Lines typed or pasted on stdin; the stream ending (EOF) is ignored.
        public var stdinLines: AsyncStream<String>
        public var pid: Int32
        /// Whether another login's process still runs (`LoginPending.processIsAlive`).
        public var isAlive: @Sendable (Int32) -> Bool

        public init(paths: DaemonPaths, oauth: OAuthConfig?, clock: any DaemonClock, transport: any HTTPTransport,
                    makeReceiver: @escaping @Sendable () -> any LoopbackSource,
                    present: @escaping @Sendable (URL, Bool) -> Void, stdinLines: AsyncStream<String>,
                    pid: Int32 = getpid(), isAlive: @escaping @Sendable (Int32) -> Bool = LoginPending.processIsAlive) {
            self.paths = paths
            self.oauth = oauth
            self.clock = clock
            self.transport = transport
            self.makeReceiver = makeReceiver
            self.present = present
            self.stdinLines = stdinLines
            self.pid = pid
            self.isAlive = isAlive
        }
    }

    public struct Result: Sendable, Equatable {
        public var token: StoredToken
        /// Whether Google sent `refresh_token_expires_in` (logged as yes/no only).
        public var hadExpiresIn: Bool
        public var pasteOnly: Bool
    }

    /// Lowercased and trimmed; nil without exactly one `@` with text on both sides.
    public static func normalizeEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !email.contains(where: \.isWhitespace) else { return nil }
        return email
    }

    public static func login(email rawEmail: String, env: Environment) async throws(LoginError) -> Result {
        guard let oauth = env.oauth else { throw .oauthMissing }
        guard let email = normalizeEmail(rawEmail) else { throw .invalidEmail(rawEmail) }
        let pendingURL = env.paths.loginPending
        // One login at a time: the pending file is shared, and a second one would take over `--callback`.
        if let other = LoginPending.read(pendingURL), other.pid != env.pid,
           env.clock.now().timeIntervalSince(other.createdAt) <= pendingMaxAge, env.isAlive(other.pid) {
            throw .anotherLoginPending(other.email)
        }

        let receiver = env.makeReceiver()
        // A task group waits for every child: the start must end when the timeout cancels it.
        let port: UInt16? = try? await race(clock: env.clock, timeout: startTimeout) {
            try await withTaskCancellationHandler { try await receiver.start() } onCancel: { receiver.stop() }
        }
        if port == nil { receiver.stop() }
        let redirectURI = port.map { "http://127.0.0.1:\($0)" } ?? pasteOnlyRedirect
        let pid = env.pid
        defer {
            receiver.stop()
            // In every outcome, but only our own file (another login may have written it meanwhile).
            if LoginPending.read(pendingURL)?.pid == pid { unlink(pendingURL.path) }
        }
        do {
            try LoginPending(port: port ?? 53682, pid: env.pid, email: email, createdAt: env.clock.now(),
                             pasteOnly: port == nil).write(to: pendingURL)
        } catch {
            throw .unavailable("login-pending.json: \(error)")
        }

        let auth = GoogleAuth(config: oauth, store: MemoryTokenStore(), transport: env.transport, now: { [clock = env.clock] in clock.now() })
        let pasteOnly = port == nil
        do {
            try await auth.signIn(redirectURI: redirectURI, loginHint: email) { url in
                env.present(url, pasteOnly)
                return try await waitForRedirect(receiver: pasteOnly ? nil : receiver, redirectURI: redirectURI,
                                                 lines: env.stdinLines, clock: env.clock)
            }
        } catch let error as LoginError {
            throw error
        } catch let error as AuthError {
            switch error {
            case .denied(let what): throw .denied(what)
            case .stateMismatch: throw .denied("state")
            case .invalidGrant: throw .denied("invalid_grant")
            case .badResponse, .notSignedIn: throw .unavailable("token endpoint")
            }
        } catch {
            throw .unavailable(String(describing: error))
        }

        let signedIn: String
        do {
            signedIn = try await LiveGmailClient(auth: auth, transport: env.transport).profileEmail().lowercased()
        } catch {
            throw .unavailable("profile")
        }
        guard signedIn == email else { throw .wrongAccount(signedIn: signedIn, expected: email) }
        guard let tokens = await auth.currentTokens(),
              let token = StoredToken(account: email, clientID: oauth.clientID, tokens: tokens) else {
            throw .unavailable("tokens")
        }
        do {
            try FileTokenStore.write(token, to: env.paths.token(email))
        } catch {
            throw .unavailable("token file: \(error)")
        }
        return Result(token: token, hadExpiresIn: tokens.refreshTokenExpiresAt != nil, pasteOnly: pasteOnly)
    }

    /// Races the loopback callback, a pasted URL on stdin and the overall timeout.
    static func waitForRedirect(receiver: (any LoopbackSource)?, redirectURI: String, lines: AsyncStream<String>,
                                clock: any DaemonClock) async throws -> URL {
        try await race(clock: clock, timeout: overallTimeout) {
            try await withThrowingTaskGroup(of: URL.self) { group in
                if let receiver {
                    group.addTask {
                        let params = try await withTaskCancellationHandler {
                            try await receiver.waitForCallback()
                        } onCancel: {
                            receiver.stop()
                        }
                        return callbackURL(redirectURI: redirectURI, params: params)
                    }
                }
                group.addTask {
                    for await line in lines {
                        if let url = parsePastedURL(line) { return url }
                    }
                    // EOF on stdin is ignored: keep waiting for the other sources (or the timeout).
                    try await clock.sleep(until: .distantFuture)
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw LoginError.timeout }
                group.cancelAll()
                return first
            }
        }
    }

    /// The redirect URL rebuilt from the loopback's query parameters (sorted, so it is deterministic).
    public static func callbackURL(redirectURI: String, params: [String: String]) -> URL {
        var c = URLComponents(string: redirectURI) ?? URLComponents()
        if c.path.isEmpty { c.path = "/" }
        c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    /// A pasted line that is an `http://127.0.0.1…` URL (quotes and angle brackets around it are dropped).
    public static func parsePastedURL(_ line: String) -> URL? {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"<>")))
        guard let c = URLComponents(string: trimmed), c.scheme?.lowercased() == "http", c.host == "127.0.0.1",
              let items = c.queryItems, items.contains(where: { $0.name == "code" || $0.name == "error" }) else { return nil }
        return c.url
    }

    /// `login --callback '<url>'`: only `http://127.0.0.1:<pending port>/…` with a code or error, while a
    /// login waits (pending file under 10 min old, its process alive, and listening: not paste-only).
    public static func validateCallback(_ text: String, pending: LoginPending?, now: Date,
                                        isAlive: (Int32) -> Bool = LoginPending.processIsAlive) throws(LoginError) -> URL {
        guard let pending else { throw .noPendingLogin }
        guard now.timeIntervalSince(pending.createdAt) <= pendingMaxAge else { throw .pendingExpired }
        guard isAlive(pending.pid) else { throw .noPendingLogin }          // interrupted (Ctrl-C): a stale file
        guard !pending.pasteOnly else { throw .pasteOnlyLogin }
        guard let url = parsePastedURL(text), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .invalidCallback("ei http://127.0.0.1-osoite, jossa on code")
        }
        guard let port = c.port.flatMap({ UInt16(exactly: $0) }), port == pending.port else {
            throw .invalidCallback("portti ei ole odottavan kirjautumisen portti \(pending.port)")
        }
        return url
    }

    /// Forwards the callback to the waiting `login` with a local GET; that is the whole forward.
    public static func forwardCallback(_ text: String, paths: DaemonPaths, now: Date,
                                       get: @Sendable (URL) async throws -> Void) async throws(LoginError) {
        let url = try validateCallback(text, pending: LoginPending.read(paths.loginPending), now: now)
        do {
            try await get(url)
        } catch {
            throw .forwardFailed(String(describing: error))
        }
    }

    /// The first of `body` and a timeout on `clock`.
    static func race<T: Sendable>(clock: any DaemonClock, timeout: TimeInterval,
                                  _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let deadline = clock.now().addingTimeInterval(timeout)
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await clock.sleep(until: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw LoginError.timeout }
            return value
        }
    }
}
