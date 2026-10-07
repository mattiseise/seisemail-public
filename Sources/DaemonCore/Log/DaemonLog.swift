import Foundation
import os
import Synchronization

/// `daemon.log` (design §11.1). One line per event, e.g.
/// `2026-10-06T09:14:02.041+03:00 INFO   matti@gmail.com wake woken=1 cancelled=0 deleted=1 next=2026-10-06T10:30Z units=63`.
/// Never tokens, codes, the consent URL, bodies, subjects or sender addresses: thread IDs, rule IDs,
/// counts and units only. `notice` and `error` are mirrored to the unified log with private fields.
public final class DaemonLog: Sendable {
    public enum Level: String, Sendable, Comparable, CaseIterable {
        case debug, info, notice, error

        var tag: String {
            switch self {
            case .debug: "DEBUG "
            case .info: "INFO  "
            case .notice: "NOTICE"
            case .error: "ERROR "
            }
        }

        private var rank: Int { Level.allCases.firstIndex(of: self)! }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    private let sink: any LogSink
    private let debugEnabled: Bool
    private let now: @Sendable () -> Date
    private let mirror: Bool
    private let timeZone: TimeZone
    private static let unified = Logger(subsystem: "fi.mak8r.mail", category: "daemon")

    /// `debug`: `MAK8R_DAEMON_DEBUG=1`. `mirror`: notice/error also to `os.Logger` (off in tests).
    public init(sink: any LogSink, debug: Bool = false, now: @escaping @Sendable () -> Date = { Date() },
                mirror: Bool = true, timeZone: TimeZone = .current) {
        self.sink = sink
        self.debugEnabled = debug
        self.now = now
        self.mirror = mirror
        self.timeZone = timeZone
    }

    public func log(_ level: Level, _ account: String?, _ message: String) {
        guard level != .debug || debugEnabled else { return }
        let text = Sanitize.line(message)
        sink.write("\(Self.timestamp(now(), timeZone: timeZone)) \(level.tag) \(account ?? "-") \(text)")
        guard mirror, level >= .notice else { return }
        let who = account ?? "-"
        if level == .error {
            Self.unified.error("\(who, privacy: .private) \(text, privacy: .private)")
        } else {
            Self.unified.notice("\(who, privacy: .private) \(text, privacy: .private)")
        }
    }

    public func debug(_ account: String?, _ message: String) { log(.debug, account, message) }
    public func info(_ account: String?, _ message: String) { log(.info, account, message) }
    public func notice(_ account: String?, _ message: String) { log(.notice, account, message) }
    public func error(_ account: String?, _ message: String) { log(.error, account, message) }

    /// `2026-10-06T09:14:02.041+03:00`
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let ms = min(999, (c.nanosecond ?? 0) / 1_000_000)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d%@%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms,
                      sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
    }

    /// `2026-10-06T10:30Z` (UTC minutes), for `next=`.
    public static func utcMinute(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}

/// A sink that keeps lines in memory (`once`, previews). Tests may use their own.
public final class MemoryLogSink: LogSink {
    private let storage = Mutex<[String]>([])

    public init() {}

    public func write(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    public var lines: [String] { storage.withLock { $0 } }
}

/// Discards everything.
public struct NullLogSink: LogSink {
    public init() {}
    public func write(_ line: String) {}
}

