import CryptoKit
import Darwin
import Foundation
import MailCore
import os
import Synchronization

private let log = Logger(subsystem: "fi.mak8r.mail", category: "daemon")

/// `daemon/tokens/<key>.json` (design §8.1): the refresh token and its metadata, never an access token.
public struct StoredToken: Codable, Sendable, Equatable {
    public var schema = 1
    public var account: String
    /// Not secret; detects a changed OAuth client.
    public var clientID: String
    public var refreshToken: String
    public var consentedAt: Date
    public var refreshTokenExpiresAt: Date?

    public init(schema: Int = 1, account: String, clientID: String, refreshToken: String,
                consentedAt: Date, refreshTokenExpiresAt: Date? = nil) {
        self.schema = schema
        self.account = account
        self.clientID = clientID
        self.refreshToken = refreshToken
        self.consentedAt = consentedAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    /// Google's `refresh_token_expires_in` when it came, else consent + 7 days − 10 min (Testing mode).
    public var expiresAt: Date { refreshTokenExpiresAt ?? consentedAt.addingTimeInterval(7 * 86_400 - 600) }

    public var fingerprint: TokenFingerprint { TokenFingerprint(refreshToken: refreshToken) }

    /// From a fresh sign-in. nil without `consentedAt` (only `exchange` sets it).
    public init?(account: String, clientID: String, tokens: TokenSet) {
        guard let consentedAt = tokens.consentedAt else { return nil }
        self.init(account: account.lowercased(), clientID: clientID, refreshToken: tokens.refreshToken,
                  consentedAt: consentedAt, refreshTokenExpiresAt: tokens.refreshTokenExpiresAt)
    }

    static var encoder: JSONEncoder { DaemonJSON.encoder() }
    static var decoder: JSONDecoder { DaemonJSON.decoder() }
}

/// SHA-256 of the refresh token, first 8 hex digits. Logged and stored in state; never the token itself.
public struct TokenFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let short: String

    public init(short: String) {
        self.short = short
    }

    public init(refreshToken: String) {
        let digest = SHA256.hash(data: Data(refreshToken.utf8))
        short = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { short }

    public init(from decoder: any Decoder) throws {
        short = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(short)
    }
}

public enum TokenFileError: Error, Equatable, Sendable {
    /// errno of the failed open/read.
    case unreadable(Int32)
    /// Not a schema-1 `StoredToken`.
    case corrupt
}

/// `TokenStore` for the daemon's `GoogleAuth` (D5). `load()` yields the refresh token with an empty, expired
/// access token, so the first request refreshes. `save` writes only when Google rotated the refresh token
/// **and** the file still holds the token this store loaded: a `login` that replaced the file meanwhile is
/// never overwritten. `clear()` (GoogleAuth's reaction to `invalid_grant`) never deletes: only `logout` does.
public final class FileTokenStore: TokenStore {
    private struct State {
        var loaded: StoredToken?
    }

    public let fileURL: URL
    private let readOnly: Bool
    private let state = Mutex(State())
    /// A rotated token that could not be saved (Finnish, no path or token): for `daemon.log`.
    private let report: (@Sendable (String) -> Void)?

    public init(fileURL: URL, readOnly: Bool = false, report: (@Sendable (String) -> Void)? = nil) {
        self.fileURL = fileURL
        self.readOnly = readOnly
        self.report = report
    }

    // MARK: TokenStore

    public func load() -> TokenSet? {
        let token: StoredToken?
        do {
            token = try read()
        } catch {
            log.error("token file unreadable: \(String(describing: error), privacy: .public)")
            token = nil
        }
        state.withLock { $0.loaded = token }
        guard let token else { return nil }
        return TokenSet(accessToken: "", refreshToken: token.refreshToken, expiresAt: .distantPast,
                        consentedAt: token.consentedAt, refreshTokenExpiresAt: token.refreshTokenExpiresAt)
    }

    public func save(_ tokens: TokenSet) {
        guard !readOnly, let loaded = state.withLock({ $0.loaded }) else { return }
        // Every refresh calls save with the same refresh token: nothing to write (the access token stays in memory).
        guard tokens.refreshToken != loaded.refreshToken else { return }
        var next = loaded
        next.refreshToken = tokens.refreshToken
        do {
            // Check and rename under the token lock, so a `login` writing meanwhile is never overwritten.
            let saved = try Self.withFileLock(fileURL) { () throws -> Bool in
                guard (try? read())?.refreshToken == loaded.refreshToken else { return false }
                try Self.writeUnlocked(next, to: fileURL)
                return true
            }
            guard saved else {
                log.notice("refresh token rotated but the file changed meanwhile (new login?); not overwriting")
                return
            }
            state.withLock { $0.loaded = next }
            log.notice("refresh token rotated, saved fp=\(next.fingerprint.short, privacy: .public)")
        } catch {
            let code = (error as? FileError)?.code ?? 0
            log.error("saving rotated refresh token failed: errno \(code, privacy: .public) \(String(describing: error), privacy: .private)")
            report?("uusittua tokenia ei voitu tallentaa (errno \(code)): käytössä vain muistissa, kunnes daemon käynnistyy uudelleen")
        }
    }

    public func clear() {
        log.notice("token cleared in memory (invalid_grant); the file stays until logout")
    }

    // MARK: File access

    /// nil when the file is missing. Repairs group/other permission bits to 0600 (logged).
    public func read() throws(TokenFileError) -> StoredToken? {
        let data: Data?
        do {
            data = try AtomicFile.read(fileURL)
        } catch let error as FileError {
            throw .unreadable(error.code)
        } catch {
            throw .unreadable(EIO)
        }
        guard let data else { return nil }
        if let mode = AtomicFile.mode(fileURL), mode & 0o077 != 0 {
            if chmod(fileURL.path, 0o600) == 0 {
                log.notice("token file mode \(String(mode, radix: 8), privacy: .public) repaired to 0600")
            }
        }
        guard let token = try? StoredToken.decoder.decode(StoredToken.self, from: data), token.schema == 1,
              !token.refreshToken.isEmpty else { throw .corrupt }
        return token
    }

    /// Atomic 0600 write; the folder is created 0700. Only `login` and `debug invalidate-token` call this.
    public static func write(_ token: StoredToken, to url: URL) throws {
        try withFileLock(url) { try writeUnlocked(token, to: url) }
    }

    static func writeUnlocked(_ token: StoredToken, to url: URL) throws {
        try AtomicFile.ensureDirectory(url.deletingLastPathComponent(), mode: 0o700)
        try AtomicFile.write(try StoredToken.encoder.encode(token), to: url, mode: 0o600)
    }

    /// `tokens/.<key>.json.lock`: every writer holds it around its check and rename (never listed as an account).
    static func lockURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".lock")
    }

    /// Runs `body` holding an exclusive `flock` on the token file's lock file (across processes).
    static func withFileLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try AtomicFile.ensureDirectory(url.deletingLastPathComponent(), mode: 0o700)
        let lock = lockURL(url)
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileError("open", lock.path) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw FileError("flock", lock.path) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// `debug invalidate-token`: replaces the refresh token with random garbage and keeps everything else,
    /// so the daemon's next refresh meets Google's real `invalid_grant` (§16 stage 5). Throws when there is
    /// no readable token.
    @discardableResult
    public static func invalidate(at url: URL) throws -> StoredToken {
        try withFileLock(url) {
            guard var token = try FileTokenStore(fileURL: url, readOnly: true).read() else {
                throw TokenFileError.unreadable(ENOENT)
            }
            token.refreshToken = "invalidated-" + UUID().uuidString.lowercased()
            try writeUnlocked(token, to: url)
            return token
        }
    }

    /// `logout` only. A missing file is fine.
    public static func delete(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT { throw FileError("unlink", url.path) }
    }

    /// Re-reads the file: a cheap stat + read. nil when missing or unreadable.
    public func currentFingerprint() -> TokenFingerprint? {
        (try? read())?.fingerprint
    }

    /// The fingerprint of the token `load()` read (and `save` may have rotated).
    public var loadedFingerprint: TokenFingerprint? {
        state.withLock { $0.loaded?.fingerprint }
    }

    /// The token `load()` read.
    public var loadedToken: StoredToken? {
        state.withLock { $0.loaded }
    }
}
