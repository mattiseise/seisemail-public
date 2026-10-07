import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// D5 / §8.1: the daemon's token file. Only `login` writes it; GoogleAuth's refreshes never do, except a rotated
/// refresh token while the file still holds the token this store loaded (compare-and-write). `clear()` never deletes.
@Suite struct FileTokenStoreTests {
    let dir = makeTempDir().appendingPathComponent("tokens")
    var url: URL { dir.appendingPathComponent("matti@example.fi.json") }
    let consented = D(1_791_181_320)

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
    }

    func stored(_ refresh: String = "r1", expires: Date? = nil) -> StoredToken {
        StoredToken(account: "matti@example.fi", clientID: "cid.apps.googleusercontent.com", refreshToken: refresh,
                    consentedAt: consented, refreshTokenExpiresAt: expires)
    }

    func bytes() throws -> Data { try Data(contentsOf: url) }

    // MARK: Reading

    @Test func missingFileReadsNil() throws {
        let store = FileTokenStore(fileURL: url)
        #expect(try store.read() == nil)
        #expect(store.load() == nil)
        #expect(store.currentFingerprint() == nil)
    }

    @Test func corruptFileThrowsCorrupt() throws {
        try Data("{\"schema\": 1, \"refr".utf8).write(to: url)
        try setPosixMode(url, 0o600)
        let store = FileTokenStore(fileURL: url)
        #expect(throws: TokenFileError.corrupt) { try store.read() }
    }

    @Test func unreadableFileThrowsUnreadable() throws {
        try FileTokenStore.write(stored(), to: url)
        try setPosixMode(url, 0o000)
        defer { try? setPosixMode(url, 0o600) }
        let store = FileTokenStore(fileURL: url)
        #expect(throws: TokenFileError.unreadable(EACCES)) { try store.read() }
    }

    @Test func groupAndOtherBitsAreRepaired() throws {
        try FileTokenStore.write(stored(), to: url)
        try setPosixMode(url, 0o644)
        let token = try FileTokenStore(fileURL: url).read()
        #expect(token == stored())
        #expect(posixMode(url) == 0o600)
    }

    @Test func roundTrip() throws {
        let token = stored("r1", expires: consented.addingTimeInterval(604_799))
        try FileTokenStore.write(token, to: url)
        #expect(try FileTokenStore(fileURL: url).read() == token)
        #expect(posixMode(url) == 0o600)
        #expect(token.schema == 1)
    }

    @Test func writeLeavesNoTemporaryFiles() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        try FileTokenStore.write(stored("r2"), to: url)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == [".matti@example.fi.json.lock", "matti@example.fi.json"])     // the writers' lock stays
    }

    // MARK: TokenStore for GoogleAuth

    @Test func loadYieldsAnExpiredAccessTokenSoFirstUseRefreshes() throws {
        try FileTokenStore.write(stored("r1", expires: consented.addingTimeInterval(604_799)), to: url)
        let tokens = try #require(FileTokenStore(fileURL: url).load())
        #expect(tokens.accessToken == "")
        #expect(tokens.expiresAt == .distantPast)
        #expect(tokens.refreshToken == "r1")
        #expect(tokens.consentedAt == consented)
        #expect(tokens.refreshTokenExpiresAt == consented.addingTimeInterval(604_799))
    }

    @Test func refreshWithUnchangedRefreshTokenWritesNothing() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        try setMTime(url, D(1_600_000_000))
        let before = try bytes()
        let store = FileTokenStore(fileURL: url)
        _ = store.load()
        store.save(TokenSet(accessToken: "ya29.SECRET-ACCESS", refreshToken: "r1", expiresAt: D(1_791_200_000),
                            consentedAt: consented, refreshTokenExpiresAt: nil))
        #expect(try bytes() == before)
        #expect(mtime(url) == D(1_600_000_000))
        #expect(!String(decoding: try bytes(), as: UTF8.self).contains("SECRET-ACCESS"))
    }

    @Test func rotatedRefreshTokenIsWrittenWhileTheFileIsUnchanged() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let store = FileTokenStore(fileURL: url)
        _ = store.load()
        store.save(TokenSet(accessToken: "ya29.SECRET-ACCESS", refreshToken: "r1-rotated", expiresAt: D(1_791_200_000),
                            consentedAt: consented, refreshTokenExpiresAt: nil))
        let onDisk = try #require(try FileTokenStore(fileURL: url).read())
        #expect(onDisk.refreshToken == "r1-rotated")
        #expect(onDisk.consentedAt == consented)
        #expect(onDisk.account == "matti@example.fi")
        #expect(onDisk.clientID == "cid.apps.googleusercontent.com")
        #expect(posixMode(url) == 0o600)
        #expect(!String(decoding: try bytes(), as: UTF8.self).contains("SECRET-ACCESS"))    // access token stays in memory
    }

    /// V2: a daemon still holding the old token must not overwrite a newer `login`.
    @Test func saveAfterANewLoginOnDiskDoesNotOverwriteIt() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let store = FileTokenStore(fileURL: url)
        _ = store.load()
        try FileTokenStore.write(stored("r9-new-login"), to: url)               // `login` from another shell
        store.save(TokenSet(accessToken: "a", refreshToken: "r1-rotated", expiresAt: D(1_791_200_000),
                            consentedAt: consented, refreshTokenExpiresAt: nil))
        #expect(try FileTokenStore(fileURL: url).read()?.refreshToken == "r9-new-login")
        store.save(TokenSet(accessToken: "a", refreshToken: "r1", expiresAt: D(1_791_200_000)))
        #expect(try FileTokenStore(fileURL: url).read()?.refreshToken == "r9-new-login")
    }

    /// The compare-and-write is atomic against a `login` in another process: save waits for the token lock,
    /// then sees the new login and leaves it.
    @Test func saveWaitsForALoginHoldingTheTokenLock() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let store = FileTokenStore(fileURL: url)
        _ = store.load()
        let url = self.url
        let newLogin = stored("r9-new-login")
        let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), saved = DispatchSemaphore(value: 0)
        Thread {
            try? FileTokenStore.withFileLock(url) {
                locked.signal()
                release.wait()
                try FileTokenStore.writeUnlocked(newLogin, to: url)
            }
        }.start()
        locked.wait()
        let consented = self.consented
        Thread {
            store.save(TokenSet(accessToken: "a", refreshToken: "r1-rotated", expiresAt: D(1_791_200_000),
                                consentedAt: consented, refreshTokenExpiresAt: nil))
            saved.signal()
        }.start()
        #expect(saved.wait(timeout: .now() + 0.3) == .timedOut)           // waits for the login's lock
        release.signal()
        #expect(saved.wait(timeout: .now() + 5) == .success)
        #expect(try FileTokenStore(fileURL: url).read()?.refreshToken == "r9-new-login")
        #expect(store.loadedFingerprint == stored("r1").fingerprint)
    }

    @Test func theLockFileIsNeverAnAccount() throws {
        let root = makeTempDir()
        let paths = DaemonPaths(support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs"))
        let url = paths.token("matti@example.fi")
        try FileTokenStore.write(stored("r1"), to: url)
        _ = try FileTokenStore.withFileLock(url) {}
        #expect(FileManager.default.fileExists(atPath: FileTokenStore.lockURL(url).path))
        #expect(paths.tokenAccounts() == ["matti@example.fi"])
    }

    @Test func saveWithoutAFileCreatesNothing() throws {
        let store = FileTokenStore(fileURL: url)
        #expect(store.load() == nil)
        store.save(TokenSet(accessToken: "a", refreshToken: "r1", expiresAt: D(1_791_200_000)))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func readOnlyStoreNeverWrites() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let before = try bytes()
        let store = FileTokenStore(fileURL: url, readOnly: true)
        _ = store.load()
        store.save(TokenSet(accessToken: "a", refreshToken: "r1-rotated", expiresAt: D(1_791_200_000)))
        #expect(try bytes() == before)
    }

    @Test func clearKeepsTheFile() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let before = try bytes()
        let store = FileTokenStore(fileURL: url)
        _ = store.load()
        store.clear()
        #expect(try bytes() == before)
    }

    @Test func deleteRemovesTheFile() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        try FileTokenStore.delete(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Through GoogleAuth

    @Test func googleAuthRefreshDoesNotTouchTheFile() async throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let before = try bytes()
        let store = FileTokenStore(fileURL: url)
        let transport = StubTransport { _ in (200, json(["access_token": "ya29.SECRET-ACCESS", "expires_in": 3600])) }
        let auth = GoogleAuth(config: OAuthConfig(clientID: "cid.apps.googleusercontent.com", clientSecret: "s"),
                              store: store, transport: transport, now: { D(1_791_190_830) })
        #expect(try await auth.accessToken() == "ya29.SECRET-ACCESS")
        #expect(formFields(transport.requests[0])["refresh_token"] == "r1")
        #expect(try bytes() == before)
    }

    /// V3: `invalid_grant` makes GoogleAuth clear the store; the daemon's store keeps the file.
    @Test func googleAuthInvalidGrantKeepsTheFile() async throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let body = try Fixture.data("daemon_token_invalid_grant")
        let auth = GoogleAuth(config: OAuthConfig(clientID: "cid.apps.googleusercontent.com", clientSecret: "s"),
                              store: FileTokenStore(fileURL: url), transport: StubTransport { _ in (400, body) },
                              now: { D(1_791_190_830) })
        await #expect(throws: AuthError.invalidGrant) { try await auth.accessToken() }
        #expect(try FileTokenStore(fileURL: url).read()?.refreshToken == "r1")
    }

    // MARK: Fingerprint (D6)

    @Test func fingerprintIsTheFirst8HexOfSHA256() throws {
        try FileTokenStore.write(stored("1//refresh-token"), to: url)
        let store = FileTokenStore(fileURL: url)
        #expect(store.currentFingerprint()?.short == fingerprint("1//refresh-token"))
        #expect(store.currentFingerprint()?.short.count == 8)
        #expect(store.currentFingerprint()?.short.contains("refresh") == false)
    }

    @Test func loadedFingerprintStaysWhileTheFileChanges() throws {
        try FileTokenStore.write(stored("r1"), to: url)
        let store = FileTokenStore(fileURL: url)
        #expect(store.loadedFingerprint == nil)
        _ = store.load()
        #expect(store.loadedFingerprint == store.currentFingerprint())
        try FileTokenStore.write(stored("r2"), to: url)
        #expect(store.currentFingerprint()?.short == fingerprint("r2"))
        #expect(store.loadedFingerprint?.short == fingerprint("r1"))
        try FileTokenStore.delete(url)
        #expect(store.currentFingerprint() == nil)
    }

    // MARK: StoredToken

    @Test func expiryFallsBackToSevenDaysMinusTenMinutes() {
        #expect(stored().expiresAt == consented.addingTimeInterval(7 * 86_400 - 600))
        #expect(stored(expires: D(1_791_700_000)).expiresAt == D(1_791_700_000))
        #expect(stored().expiresAt == D(1_791_785_520))        // ma 12.10.2026 klo 9.12 Helsinki
    }
}
