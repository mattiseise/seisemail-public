import Foundation
import MailCore

/// Wall-clock time for the daemon's loops. Tests inject a manual clock.
public protocol DaemonClock: Sendable {
    func now() -> Date
    /// Returns at or after `until` on the wall clock. The system clock sleeps in chunks of at most 30 s
    /// and re-reads the wall clock, so a Mac sleep or a clock step never leaves a tick hours late.
    func sleep(until: Date) async throws
}

public struct SystemDaemonClock: DaemonClock {
    public static let maxChunk: TimeInterval = 30

    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(for: .seconds(min(remaining, Self.maxChunk)), tolerance: .milliseconds(100))
        }
    }
}

extension DaemonClock {
    /// The next whole minute after `date`, plus `offset` seconds (wake: +2 s, sync: +20 s).
    public func nextMinute(after date: Date, offset: TimeInterval) -> Date {
        DaemonSchedule.nextMinute(after: date, offset: offset)
    }
}

public enum DaemonSchedule {
    /// The first `hh:mm:offset` strictly after `date` (UTC minutes; Helsinki's offset is whole minutes).
    public static func nextMinute(after date: Date, offset: TimeInterval) -> Date {
        let t = date.timeIntervalSince1970
        let minute = (t / 60).rounded(.down) * 60
        let candidate = minute + offset
        return Date(timeIntervalSince1970: candidate > t ? candidate : candidate + 60)
    }

    /// The latest `hour:00` Helsinki time at or before `date`.
    public static func lastDailyBoundary(before date: Date, hour: Int, timeZone: TimeZone = SnoozePresets.helsinki) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        return today <= date ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// Start of the Helsinki day containing `date` (the daily counters reset there).
    public static func dayStart(_ date: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }
}
