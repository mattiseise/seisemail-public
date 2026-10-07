import Foundation

/// The sorter's pace (D8): at most `unitsPerMinute` in any rolling 60 s. `spend` *sleeps* until the
/// units fit instead of failing, so a page always finishes and wakes keep the rest of the daemon's share.
/// A single spend larger than the whole budget waits for an empty window and then goes through.
public actor MinuteBudget {
    public static let window: TimeInterval = 60

    private var unitsPerMinute: Int
    private let clock: any DaemonClock
    private var entries: [(at: Date, units: Int)] = []

    public init(unitsPerMinute: Int, clock: any DaemonClock) {
        self.unitsPerMinute = max(1, unitsPerMinute)
        self.clock = clock
    }

    /// Takes effect for the next spend (config reload).
    public func setUnitsPerMinute(_ value: Int) {
        unitsPerMinute = max(1, value)
    }

    public func spend(_ units: Int) async throws {
        guard units > 0 else { return }
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            // A wall-clock step back leaves entries in the future: count them as spent now, so the wait is at
            // most one window and never the size of the step.
            for i in entries.indices where entries[i].at > now { entries[i].at = now }
            entries.removeAll { now.timeIntervalSince($0.at) >= Self.window }
            let used = entries.reduce(0) { $0 + $1.units }
            if entries.isEmpty || used + units <= unitsPerMinute {
                entries.append((now, units))
                return
            }
            // Wait until enough of the window has rolled off.
            var freed = 0
            var until = now
            for entry in entries {
                freed += entry.units
                until = entry.at.addingTimeInterval(Self.window)
                if used - freed + units <= unitsPerMinute { break }
            }
            try await clock.sleep(until: until)
        }
    }

    /// Units spent in the last 60 s.
    public var spentLastMinute: Int {
        let now = clock.now()
        return entries.filter { now.timeIntervalSince($0.at) < Self.window }.reduce(0) { $0 + $1.units }
    }
}
