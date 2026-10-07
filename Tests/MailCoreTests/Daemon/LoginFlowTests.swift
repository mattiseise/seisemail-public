import Foundation
import Synchronization
import Testing
@testable import DaemonCore
@testable import MailCore

/// §8.2 `mak8r-daemon login`: the loopback receiver, a pasted redirect URL on stdin and `login --callback`
/// race under one overall timeout; the profile address is checked before anything is stored, and the
/// pending file never outlives the command. Nothing here talks to Google: the token endpoint and the
/// profile lookup are stubs, and the clock is manual.
@Suite struct LoginFlowTests {
    let root = makeTempDir()
    let paths: DaemonPaths
    let clock = TestDaemonClock(daemonEpoch)
    let oauth = OAuthConfig(clientID: "cid.apps.googleusercontent.com", clientSecret: "secret")

    init() throws {
        paths = DaemonPaths(support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs"))
        try paths.createDirectories()
    }

    /// Token endpoint answers the fixture; the profile says `profile`.
    func google(profile: String = "matti@example.fi") -> StubTransport {
        StubTransport { request in
            if request.url?.host == "oauth2.googleapis.com" {
                return (200, try Fixture.data("daemon_token_ok_expires_in"))
            }
            if request.url?.path.hasSuffix("/profile") == true {
                return (200, json(["emailAddress": profile, "historyId": "1000"]))
            }
            return (404, Data("{}".utf8))
        }
    }

    final class Presented: Sendable {
        private let state = Mutex<[(url: URL, pasteOnly: Bool, pending: LoginPending?)]>([])
        func add(_ url: URL, _ pasteOnly: Bool, _ pending: LoginPending?) { state.withLock { $0.append((url, pasteOnly, pending)) } }
        var all: [(url: URL, pasteOnly: Bool, pending: LoginPending?)] { state.withLock { $0 } }
        var first: (url: URL, pasteOnly: Bool, pending: LoginPending?)? { all.first }
    }

    func environment(receiver: FakeLoopback, transport: StubTransport, lines: AsyncStream<String>,
                     presented: Presented, onPresent: @escaping @Sendable (URL) -> Void = { _ in }) -> LoginFlow.Environment {
        let paths = self.paths
        return LoginFlow.Environment(
            paths: paths, oauth: oauth, clock: clock, transport: transport,
            makeReceiver: { receiver },
            present: { url, pasteOnly in
                presented.add(url, pasteOnly, LoginPending.read(paths.loginPending))
                onPresent(url)
            },
            stdinLines: lines, pid: 4242
        )
    }

    static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    var pendingExists: Bool { FileManager.default.fileExists(atPath: paths.loginPending.path) }

    // MARK: Sources

    @Test func pastedRedirectOnStdinSignsIn() async throws {
        let receiver = FakeLoopback(.port(50_000))
        let google = google()
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let presented = Presented()
        let env = environment(receiver: receiver, transport: google, lines: lines, presented: presented) { url in
            input.yield("not a url")
            input.yield("  '<http://127.0.0.1:53682/?state=\(Self.query(url, "state") ?? "")&code=abc>'  ")
        }
        let result = try await LoginFlow.login(email: " Matti@Example.FI ", env: env)

        #expect(result.token.account == "matti@example.fi")
        #expect(result.token.refreshToken == "1//test-refresh")
        #expect(result.token.clientID == oauth.clientID)
        #expect(result.token.consentedAt == daemonEpoch)
        #expect(result.hadExpiresIn)
        #expect(!result.pasteOnly)
        let shown = try #require(presented.first)
        #expect(Self.query(shown.url, "login_hint") == "matti@example.fi")
        #expect(Self.query(shown.url, "redirect_uri") == "http://127.0.0.1:50000")
        let exchange = try #require(google.requests.first { $0.url?.host == "oauth2.googleapis.com" })
        #expect(formFields(exchange)["code"] == "abc")
        #expect(formFields(exchange)["redirect_uri"] == "http://127.0.0.1:50000")
        let stored = try #require(try FileTokenStore(fileURL: paths.token("matti@example.fi"), readOnly: true).read())
        #expect(stored == result.token)
        #expect(posixMode(paths.token("matti@example.fi")) == 0o600)
        #expect(!pendingExists)
        #expect(receiver.stopCount >= 1)
    }

    @Test func loopbackCallbackSignsIn() async throws {
        let receiver = FakeLoopback(.port(50_001))
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        input.finish()   // EOF on stdin is ignored
        let presented = Presented()
        let env = environment(receiver: receiver, transport: google(), lines: lines, presented: presented) { url in
            receiver.deliver(["code": "xyz", "state": Self.query(url, "state") ?? ""])
        }
        let result = try await LoginFlow.login(email: "matti@example.fi", env: env)
        #expect(result.token.refreshToken == "1//test-refresh")
        #expect(!pendingExists)
    }

    @Test func pendingFileNamesThePortPidAndAccountWithoutSecrets() async throws {
        let receiver = FakeLoopback(.port(50_002))
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let presented = Presented()
        let env = environment(receiver: receiver, transport: google(), lines: lines, presented: presented) { url in
            input.yield("http://127.0.0.1:50002/?code=c&state=\(Self.query(url, "state") ?? "")")
        }
        _ = try await LoginFlow.login(email: "matti@example.fi", env: env)
        let pending = try #require(presented.first?.pending)
        #expect(pending == LoginPending(port: 50_002, pid: 4242, email: "matti@example.fi", createdAt: daemonEpoch))
        #expect(!pendingExists)
    }

    // MARK: Refusals

    @Test func stateMismatchIsRefusedAndNothingStored() async throws {
        let receiver = FakeLoopback(.port(50_003))
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let env = environment(receiver: receiver, transport: google(), lines: lines, presented: Presented()) { _ in
            input.yield("http://127.0.0.1:50003/?code=abc&state=forged")
        }
        await #expect(throws: LoginError.denied("state")) { try await LoginFlow.login(email: "matti@example.fi", env: env) }
        #expect(LoginError.denied("state").exitCode == 77)
        #expect(!FileManager.default.fileExists(atPath: paths.token("matti@example.fi").path))
        #expect(!pendingExists)
    }

    @Test func wrongAccountStoresNothingAndExits77() async throws {
        let receiver = FakeLoopback(.port(50_004))
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let env = environment(receiver: receiver, transport: google(profile: "Toinen@Example.fi"), lines: lines,
                              presented: Presented()) { url in
            input.yield("http://127.0.0.1:50004/?code=abc&state=\(Self.query(url, "state") ?? "")")
        }
        let expected = LoginError.wrongAccount(signedIn: "toinen@example.fi", expected: "matti@example.fi")
        await #expect(throws: expected) { try await LoginFlow.login(email: "matti@example.fi", env: env) }
        #expect(expected.exitCode == DaemonExitCode.wrongAccount.rawValue)
        #expect(expected.message == "Kirjauduit tilillä toinen@example.fi, odotettiin matti@example.fi. Mitään ei tallennettu.")
        #expect(paths.tokenAccounts().isEmpty)
        #expect(!pendingExists)
    }

    @Test func emailWithoutAtIsAUsageError() async throws {
        let env = environment(receiver: FakeLoopback(.port(1)), transport: google(), lines: AsyncStream { $0.finish() },
                              presented: Presented())
        await #expect(throws: LoginError.invalidEmail("matti")) { try await LoginFlow.login(email: "matti", env: env) }
        #expect(LoginError.invalidEmail("matti").exitCode == 64)
    }

    @Test func missingOAuthClientExits69() async throws {
        var env = environment(receiver: FakeLoopback(.port(1)), transport: google(), lines: AsyncStream { $0.finish() },
                              presented: Presented())
        env.oauth = nil
        await #expect(throws: LoginError.oauthMissing) { try await LoginFlow.login(email: "matti@example.fi", env: env) }
        #expect(LoginError.oauthMissing.exitCode == 69)
        #expect(LoginError.oauthMissing.message == "OAuth-asiakas puuttuu: aja make daemon")
    }

    // MARK: Timeouts

    @Test func loopbackStartTimeoutFallsBackToPasteOnly() async throws {
        let receiver = FakeLoopback(.hang)
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let presented = Presented()
        let env = environment(receiver: receiver, transport: google(), lines: lines, presented: presented) { url in
            input.yield("http://127.0.0.1:53682/?code=abc&state=\(Self.query(url, "state") ?? "")")
        }
        let task = Task { try await LoginFlow.login(email: "matti@example.fi", env: env) }
        #expect(await eventually { clock.sleeperCount >= 1 })
        clock.advance(by: LoginFlow.startTimeout)
        let result = try await task.value
        #expect(result.pasteOnly)
        let shown = try #require(presented.first)
        #expect(shown.pasteOnly)
        #expect(Self.query(shown.url, "redirect_uri") == LoginFlow.pasteOnlyRedirect)
        #expect(shown.pending?.port == 53_682)
        #expect(shown.pending?.pasteOnly == true)                          // nothing listens: --callback must refuse
        #expect(receiver.stopCount >= 1)
        #expect(!pendingExists)
    }

    @Test func overallTimeoutAfterTenMinutes() async throws {
        let receiver = FakeLoopback(.port(50_005))
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        input.finish()
        let presented = Presented()
        let env = environment(receiver: receiver, transport: google(), lines: lines, presented: presented)
        let task = Task { try await LoginFlow.login(email: "matti@example.fi", env: env) }
        #expect(await eventually { !presented.all.isEmpty && clock.sleeperCount >= 2 })
        clock.advance(by: LoginFlow.overallTimeout - 1)
        #expect(clock.sleeperCount >= 2)
        clock.advance(by: 1)
        await #expect(throws: LoginError.timeout) { try await task.value }
        #expect(LoginError.timeout.exitCode == 69)
        #expect(paths.tokenAccounts().isEmpty)
        #expect(!pendingExists)
    }

    // MARK: login --callback

    @Test func callbackAcceptsOnlyLoopbackAndThePendingPort() throws {
        let pending = LoginPending(port: 50_010, pid: 1, email: "matti@example.fi", createdAt: daemonEpoch)
        let now = daemonEpoch.addingTimeInterval(60)
        let ok = try LoginFlow.validateCallback("'http://127.0.0.1:50010/?state=s&code=c'", pending: pending, now: now)
        #expect(ok.absoluteString == "http://127.0.0.1:50010/?state=s&code=c")
        func refusal(_ text: String) -> LoginError? {
            do {
                _ = try LoginFlow.validateCallback(text, pending: pending, now: now)
                return nil
            } catch {
                return error
            }
        }
        for bad in ["http://localhost:50010/?code=c", "https://127.0.0.1:50010/?code=c", "http://127.0.0.1:50011/?code=c",
                    "http://127.0.0.1:50010/?state=s", "http://evil.example/?code=c", "kissa"] {
            let error = refusal(bad)
            #expect(error != nil, "\(bad)")
            #expect(error?.exitCode == 64, "\(bad)")
        }
        #expect(throws: LoginError.noPendingLogin) { try LoginFlow.validateCallback("http://127.0.0.1:50010/?code=c", pending: nil, now: now) }
        #expect(throws: LoginError.pendingExpired) {
            try LoginFlow.validateCallback("http://127.0.0.1:50010/?code=c", pending: pending,
                                           now: daemonEpoch.addingTimeInterval(LoginFlow.pendingMaxAge + 1))
        }
    }

    @Test func callbackWithAPortOutOfRangeIsRefusedNotACrash() throws {
        let pending = LoginPending(port: 53_682, pid: 1, email: "matti@example.fi", createdAt: daemonEpoch)
        for text in ["http://127.0.0.1:99999/?code=abc", "http://127.0.0.1:65536/?code=abc"] {
            #expect(throws: LoginError.self) { try LoginFlow.validateCallback(text, pending: pending, now: daemonEpoch) }
        }
    }

    @Test func callbackForAPasteOnlyLoginSaysWhereToPaste() throws {
        var pending = LoginPending(port: 53_682, pid: 1, email: "matti@example.fi", createdAt: daemonEpoch)
        pending.pasteOnly = true
        #expect(throws: LoginError.pasteOnlyLogin) {
            try LoginFlow.validateCallback("http://127.0.0.1:53682/?code=c&state=s", pending: pending, now: daemonEpoch)
        }
        #expect(LoginError.pasteOnlyLogin.message.contains("ikkuna"))
    }

    @Test func callbackForALoginWhoseProcessIsGoneIsRefused() throws {
        let pending = LoginPending(port: 50_030, pid: 999_999, email: "matti@example.fi", createdAt: daemonEpoch)
        #expect(throws: LoginError.noPendingLogin) {
            try LoginFlow.validateCallback("http://127.0.0.1:50030/?code=c&state=s", pending: pending, now: daemonEpoch,
                                           isAlive: { _ in false })
        }
    }

    /// A pending file older than this module's format (no `pasteOnly`) still reads.
    @Test func pendingFileWithoutPasteOnlyDecodes() throws {
        try Data(#"{"port":50040,"pid":7,"email":"matti@example.fi","createdAt":"2026-10-05T09:00:30Z"}"#.utf8)
            .write(to: paths.loginPending)
        let pending = try #require(LoginPending.read(paths.loginPending))
        #expect(pending.port == 50_040)
        #expect(!pending.pasteOnly)
    }

    @Test func aSecondLoginWhileOneWaitsIsRefusedAndLeavesItsFile() async throws {
        let other = LoginPending(port: 50_050, pid: 1, email: "toinen@example.fi", createdAt: daemonEpoch)
        try other.write(to: paths.loginPending)
        let (lines, _) = AsyncStream.makeStream(of: String.self)
        let env = environment(receiver: FakeLoopback(.port(50_051)), transport: google(), lines: lines, presented: Presented())
        await #expect(throws: LoginError.anotherLoginPending("toinen@example.fi")) {
            try await LoginFlow.login(email: "matti@example.fi", env: env)
        }
        #expect(LoginPending.read(paths.loginPending) == other)
    }

    @Test func aLoginEndingNeverDeletesAnotherLoginsPendingFile() async throws {
        let receiver = FakeLoopback(.port(50_060))
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let paths = self.paths
        let other = LoginPending(port: 50_061, pid: 1, email: "toinen@example.fi", createdAt: daemonEpoch)
        let env = environment(receiver: receiver, transport: google(), lines: lines, presented: Presented()) { url in
            try? other.write(to: paths.loginPending)                      // e.g. a stale login started later
            input.yield("http://127.0.0.1:50060/?code=abc&state=forged")
        }
        await #expect(throws: LoginError.denied("state")) { try await LoginFlow.login(email: "matti@example.fi", env: env) }
        #expect(LoginPending.read(paths.loginPending) == other)
    }

    @Test func callbackForwardIsOneLocalGet() async throws {
        try LoginPending(port: 50_020, pid: 1, email: "matti@example.fi", createdAt: daemonEpoch).write(to: paths.loginPending)
        let fetched = Mutex<[URL]>([])
        try await LoginFlow.forwardCallback("http://127.0.0.1:50020/?code=c&state=s", paths: paths, now: daemonEpoch) { url in
            fetched.withLock { $0.append(url) }
        }
        #expect(fetched.withLock { $0 } == [URL(string: "http://127.0.0.1:50020/?code=c&state=s")!])
        await #expect(throws: LoginError.self) {
            try await LoginFlow.forwardCallback("http://127.0.0.1:50021/?code=c", paths: paths, now: daemonEpoch) { _ in }
        }
    }

    @Test func everyErrorHasAFinnishMessage() {
        let errors: [LoginError] = [.oauthMissing, .invalidEmail("x"), .wrongAccount(signedIn: "a@b", expected: "c@d"),
                                    .denied("scope"), .denied("state"), .denied("access_denied"), .timeout,
                                    .unavailable("profile"), .noPendingLogin, .pendingExpired,
                                    .invalidCallback("portti"), .forwardFailed("x"), .pasteOnlyLogin,
                                    .anotherLoginPending("toinen@example.fi")]
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains("refresh"))
        }
        #expect(LoginError.denied("scope").message.contains("Gmail"))
        #expect(LoginError.timeout.message.contains("10 minuu"))
    }
}

/// A `LoopbackSource` that answers `start()` with a port, never (until stopped), or an error, and delivers
/// a callback when the test says so.
final class FakeLoopback: LoopbackSource, Sendable {
    enum Start: Sendable {
        case port(UInt16)
        case hang
        case fail
    }

    private struct State {
        var startWaiter: CheckedContinuation<UInt16, any Error>?
        var callbackWaiter: CheckedContinuation<[String: String], any Error>?
        var delivered: [String: String]?
        var stopped = false
        var stopCount = 0
    }

    private let behaviour: Start
    private let state = Mutex(State())

    init(_ behaviour: Start) {
        self.behaviour = behaviour
    }

    var stopCount: Int { state.withLock { $0.stopCount } }

    func start() async throws -> UInt16 {
        switch behaviour {
        case .port(let port):
            return port
        case .fail:
            throw URLError(.cannotConnectToHost)
        case .hang:
            return try await withCheckedThrowingContinuation { continuation in
                let stopped = state.withLock { s -> Bool in
                    if s.stopped { return true }
                    s.startWaiter = continuation
                    return false
                }
                if stopped { continuation.resume(throwing: CancellationError()) }
            }
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { s -> Result<[String: String], any Error>? in
                if let params = s.delivered { return .success(params) }
                if s.stopped { return .failure(CancellationError()) }
                s.callbackWaiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func deliver(_ params: [String: String]) {
        let waiter = state.withLock { s -> CheckedContinuation<[String: String], any Error>? in
            s.delivered = params
            defer { s.callbackWaiter = nil }
            return s.callbackWaiter
        }
        waiter?.resume(returning: params)
    }

    func stop() {
        let (start, callback) = state.withLock { s in
            s.stopped = true
            s.stopCount += 1
            defer {
                s.startWaiter = nil
                s.callbackWaiter = nil
            }
            return (s.startWaiter, s.callbackWaiter)
        }
        start?.resume(throwing: CancellationError())
        callback?.resume(throwing: CancellationError())
    }
}
