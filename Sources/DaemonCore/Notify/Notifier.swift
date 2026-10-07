import Foundation

/// Fan-out with a throttle: every event goes to the log; hook-worthy ones (`DaemonEvent.forHook`) go to
/// the other sinks (the command hook). An identical event within `dedupeWindow` is dropped, so two
/// loops reporting the same thing produce one notice. The runners do the long throttles themselves
/// (needsLogin once + daily, persistentError once per 24 h) because those must survive restarts.
public actor NotifierHub: DaemonNotifier {
    private let log: DaemonLog
    private let sinks: [any DaemonNotifier]
    private let now: @Sendable () -> Date
    private let dedupeWindow: TimeInterval
    private var recent: [(event: DaemonEvent, at: Date)] = []

    public init(log: DaemonLog, sinks: [any DaemonNotifier] = [], now: @escaping @Sendable () -> Date = { Date() },
                dedupeWindow: TimeInterval = 60) {
        self.log = log
        self.sinks = sinks
        self.now = now
        self.dedupeWindow = dedupeWindow
    }

    public func post(_ e: DaemonEvent) async {
        let at = now()
        recent.removeAll { at.timeIntervalSince($0.at) >= dedupeWindow }
        guard !recent.contains(where: { $0.event == e }) else { return }
        recent.append((e, at))
        log.log(e.level, e.account, "ilmoitus \(e.name): \(e.text(now: at))")
        guard e.forHook else { return }
        for sink in sinks { await sink.post(e) }
    }
}

/// Collects events in memory (`once` output; tests may use their own).
public actor RecordingDaemonNotifier: DaemonNotifier {
    public private(set) var events: [DaemonEvent] = []

    public init() {}

    public func post(_ e: DaemonEvent) async {
        events.append(e)
    }
}

/// Throttle for one kind of persistent trouble (§10): notify once the condition has lasted `after`,
/// then at most once per `repeatEvery`, and start over when it clears.
public struct PersistentErrorTracker: Sendable, Equatable {
    public var after: TimeInterval
    /// Also require this many consecutive failing observations.
    public var afterCount: Int
    public var repeatEvery: TimeInterval
    public private(set) var since: Date?
    public private(set) var lastNotified: Date?
    /// Consecutive failing observations (for count-based thresholds).
    public private(set) var streak = 0

    public init(after: TimeInterval, afterCount: Int = 0, repeatEvery: TimeInterval = 86_400) {
        self.after = after
        self.afterCount = afterCount
        self.repeatEvery = repeatEvery
    }

    /// Records one observation. Returns `since` when a notification is due now.
    public mutating func observe(failing: Bool, at now: Date) -> Date? {
        guard failing else {
            since = nil
            lastNotified = nil
            streak = 0
            return nil
        }
        streak += 1
        let start = since ?? now
        since = start
        guard now.timeIntervalSince(start) >= after, streak >= afterCount else { return nil }
        if let lastNotified, now.timeIntervalSince(lastNotified) < repeatEvery { return nil }
        lastNotified = now
        return start
    }
}
