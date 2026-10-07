import Foundation
import MailCore

/// Every file the daemon reads or writes (design §9.1). Tests pass temporary directories.
public struct DaemonPaths: Sendable, Equatable {
    /// `~/Library/Application Support/Mak8rMail` (`AppPaths.supportDirectory`).
    public var support: URL
    /// `support/daemon`, 0700.
    public var daemon: URL
    /// `daemon/tokens`, 0700.
    public var tokens: URL
    /// `daemon/requests`, 0700.
    public var requests: URL
    /// `support/bin`.
    public var bin: URL
    /// `~/Library/Logs/Mak8rMail`, 0700.
    public var logs: URL
    /// `support/daemon.json`.
    public var config: URL
    /// `support/rules.json` (conventions §2).
    public var rules: URL
    /// `daemon/status.json`.
    public var status: URL
    /// `daemon/starts.json`.
    public var starts: URL
    /// `daemon/daemon.lock`.
    public var lock: URL
    /// `daemon/login-pending.json`: port, pid, email, createdAt; no secrets.
    public var loginPending: URL

    public init(support: URL, logs: URL) {
        self.support = support
        self.logs = logs
        daemon = support.appendingPathComponent("daemon", isDirectory: true)
        tokens = daemon.appendingPathComponent("tokens", isDirectory: true)
        requests = daemon.appendingPathComponent("requests", isDirectory: true)
        bin = support.appendingPathComponent("bin", isDirectory: true)
        config = support.appendingPathComponent("daemon.json")
        rules = support.appendingPathComponent("rules.json")
        status = daemon.appendingPathComponent("status.json")
        starts = daemon.appendingPathComponent("starts.json")
        lock = daemon.appendingPathComponent("daemon.lock")
        loginPending = daemon.appendingPathComponent("login-pending.json")
    }

    public static var live: DaemonPaths {
        DaemonPaths(support: AppPaths.supportDirectory, logs: AppPaths.logsDirectory)
    }

    /// `MAK8R_DAEMON_SUPPORT_DIR` replaces the support folder (tests and dry runs of the CLI, never the
    /// LaunchAgent); `MAK8R_DAEMON_LOGS_DIR` the logs folder, which otherwise sits beside it as `<support>/logs`.
    /// Without the first, `live`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> DaemonPaths {
        guard let support = environment["MAK8R_DAEMON_SUPPORT_DIR"], !support.isEmpty else { return .live }
        let supportURL = URL(fileURLWithPath: support, isDirectory: true).standardizedFileURL
        let logs = environment["MAK8R_DAEMON_LOGS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? supportURL.appendingPathComponent("logs", isDirectory: true)
        return DaemonPaths(support: supportURL, logs: logs)
    }

    /// `tokens/<key>.json`
    public func token(_ email: String) -> URL {
        tokens.appendingPathComponent(Self.key(email) + ".json")
    }

    /// `daemon/state-<key>.json`
    public func state(_ email: String) -> URL {
        daemon.appendingPathComponent("state-" + Self.key(email) + ".json")
    }

    /// `logs/daemon.log`
    public var daemonLog: URL { logs.appendingPathComponent("daemon.log") }
    /// `logs/decisions.jsonl`
    public var decisions: URL { logs.appendingPathComponent("decisions.jsonl") }
    /// launchd's crash output (truncated at start when over 1 MiB).
    public var stdoutLog: URL { logs.appendingPathComponent("daemon.stdout.log") }
    public var stderrLog: URL { logs.appendingPathComponent("daemon.stderr.log") }

    /// `requests/backfill-<key>-<yyyyMMddHHmmss>.json`
    public func backfillRequest(_ email: String, at date: Date) -> URL {
        requests.appendingPathComponent("backfill-\(Self.key(email))-\(Self.stamp(date)).json")
    }

    /// `requests/note-<key>-<yyyyMMddHHmmss>.json` (`debug note-now` while the daemon runs).
    public func noteRequest(_ email: String, at date: Date) -> URL {
        requests.appendingPathComponent("note-\(Self.key(email))-\(Self.stamp(date)).json")
    }

    /// `<prefix><digits>.json` exactly: an account whose key merely starts like another's never matches.
    public static func isRequest(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
        let stamp = name.dropFirst(prefix.count).dropLast(5)
        return !stamp.isEmpty && stamp.allSatisfy(\.isASCII) && stamp.allSatisfy(\.isNumber)
    }

    /// Lowercased; every byte outside `[a-z0-9@._+-]` becomes `%XX`. File-name safe and reversible.
    public static func key(_ email: String) -> String {
        var out = ""
        for byte in email.lowercased().utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "@"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "-"):
                out.append(Character(Unicode.Scalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Inverse of `key` (the lowercased address); nil if `key` is not one.
    public static func email(fromKey key: String) -> String? {
        guard let decoded = key.removingPercentEncoding, Self.key(decoded) == key else { return nil }
        return decoded
    }

    /// Accounts with a token file, by file name, sorted.
    public func tokenAccounts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tokens.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { Self.email(fromKey: String($0.dropLast(5))) }
            .sorted()
    }

    /// Creates `daemon/`, `tokens/`, `requests/` and the logs folder with mode 0700 (and tightens existing ones).
    public func createDirectories() throws {
        for url in [support, daemon, tokens, requests, logs] {
            try AtomicFile.ensureDirectory(url, mode: url == support ? 0o755 : 0o700)
        }
    }

    /// UTC `yyyyMMddHHmmss`, for request and quarantine file names.
    public static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
