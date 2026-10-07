import Foundation
import Synchronization

/// Crash-loop guard (D16): `daemon/starts.json` keeps the process starts that count, and five or more within
/// 10 min put this process in safe mode (sorting off; wake keeps its mode).
///
/// Only unclean starts count. The graceful path (SIGTERM → state flushed → `status.json` stopped) ends with
/// `recordCleanShutdown`, a marker the next start consumes instead of counting itself. A crash or `kill -9`
/// leaves no marker, so the start after it counts.
public struct StartGuard: Sendable {
    public struct Result: Sendable, Equatable {
        /// Counted (unclean) starts within the window, this one included unless it is `clean`.
        public var starts: Int
        public var safeMode: Bool
        /// The previous process stopped gracefully: this start was not counted and is never safe mode.
        public var clean = false

        public init(starts: Int, safeMode: Bool, clean: Bool = false) {
            self.starts = starts
            self.safeMode = safeMode
            self.clean = clean
        }
    }

    /// `starts.json`. Before the clean-shutdown marker it was a bare array of dates, which is still read.
    struct Record: Codable, Equatable {
        var starts: [Date] = []
        var cleanShutdownAt: Date?
    }

    public let url: URL
    public let window: TimeInterval
    public let threshold: Int

    public init(url: URL, window: TimeInterval = 600, threshold: Int = 5) {
        self.url = url
        self.window = window
        self.threshold = threshold
    }

    /// Records a start at `now`. An unreadable file counts as empty; a failed write is ignored (the guard
    /// must never stop the daemon from starting).
    @discardableResult
    public func recordStart(at now: Date) -> Result {
        var record = read()
        record.starts = record.starts.filter { now.timeIntervalSince($0) < window && $0 <= now.addingTimeInterval(60) }
        let clean = record.cleanShutdownAt != nil
        record.cleanShutdownAt = nil
        if !clean { record.starts.append(now) }
        write(record)
        return Result(starts: record.starts.count, safeMode: !clean && record.starts.count >= threshold, clean: clean)
    }

    /// The graceful stop's marker: the next start does not count. Written last, after the state is flushed.
    public func recordCleanShutdown(at now: Date) {
        var record = read()
        record.cleanShutdownAt = now
        write(record)
    }

    func read() -> Record {
        guard let data = (try? AtomicFile.read(url)).flatMap({ $0 }) else { return Record() }
        let decoder = DaemonJSON.decoder()
        if let record = try? decoder.decode(Record.self, from: data) { return record }
        if let legacy = try? decoder.decode([Date].self, from: data) { return Record(starts: legacy) }
        return Record()
    }

    private func write(_ record: Record) {
        if let data = try? DaemonJSON.encoder(pretty: false).encode(record) {
            try? AtomicFile.write(data, to: url, mode: 0o600)
        }
    }
}

/// This process's safe mode (D16). It only ever ends: after `stableRun` (30 min) of running without a
/// restart, the supervisor clears it and sorting resumes in the configured mode. Shared by the supervisor
/// (status) and the runners (sync gate).
public final class SafeMode: Sendable {
    public static let stableRun: TimeInterval = 30 * 60

    public struct Snapshot: Sendable, Equatable {
        public var active: Bool
        /// While active: when it ends by itself if the process keeps running.
        public var clearsAt: Date?
        /// When it ended (this process was in safe mode and ran stably).
        public var clearedAt: Date?

        public init(active: Bool, clearsAt: Date? = nil, clearedAt: Date? = nil) {
            self.active = active
            self.clearsAt = clearsAt
            self.clearedAt = clearedAt
        }
    }

    private let state: Mutex<Snapshot>

    /// `since`: the process start.
    public init(active: Bool, since: Date, stableRun: TimeInterval = SafeMode.stableRun) {
        state = Mutex(Snapshot(active: active, clearsAt: active ? since.addingTimeInterval(stableRun) : nil))
    }

    public var isActive: Bool { state.withLock { $0.active } }
    public var snapshot: Snapshot { state.withLock { $0 } }

    /// Ends safe mode once `now` reaches `clearsAt`. True only for the call that ended it.
    public func clearIfStable(now: Date) -> Bool {
        state.withLock { s in
            guard s.active, let clearsAt = s.clearsAt, now >= clearsAt else { return false }
            s = Snapshot(active: false, clearsAt: nil, clearedAt: now)
            return true
        }
    }
}
