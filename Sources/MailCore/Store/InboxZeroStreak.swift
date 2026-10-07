import Foundation
import Observation

/// Inbox 0 weeks (Matti 7.10.2026): per account, the Mondays (Helsinki civil days) of the weeks in which its inbox
/// was seen empty at least once. Device-local like the daily counter (conventions §3), never synced.
public struct InboxZeroWeeks: Codable, Sendable, Equatable {
    /// Lowercased email → Mondays, ascending, unique.
    public private(set) var mondays: [String: [Int]] = [:]

    public init() {}

    /// The Monday of `day`'s ISO week.
    public static func monday(of day: Int) -> Int {
        day - (CivilTime.isoWeekday(days: day) - 1)
    }

    /// Adds `now`'s week; false when it was already there.
    @discardableResult
    public mutating func record(email: String, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> Bool {
        let key = email.lowercased()
        let week = Self.monday(of: CivilTime.localDay(of: now, in: timeZone))
        var list = mondays[key] ?? []
        guard !list.contains(week) else { return false }
        list.append(week)
        list.sort()
        mondays[key] = list
        return true
    }

    /// Consecutive weeks up to this week, or up to last week while this week has no Inbox 0 yet (the week is not
    /// over); 0 when neither has one.
    public func streak(email: String, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> Int {
        let weeks = Set(mondays[email.lowercased()] ?? [])
        var week = Self.monday(of: CivilTime.localDay(of: now, in: timeZone))
        if !weeks.contains(week) { week -= 7 }
        var count = 0
        while weeks.contains(week) {
            count += 1
            week -= 7
        }
        return count
    }
}

/// The device's Inbox 0 weeks in `seise-inbox-zero-weeks.json`.
@MainActor @Observable
public final class InboxZeroStreakStore {
    public nonisolated static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("seise-inbox-zero-weeks.json")
    }

    public private(set) var weeks: InboxZeroWeeks
    @ObservationIgnored private let file: SettingsFile<InboxZeroWeeks>
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(file: SettingsFile<InboxZeroWeeks>, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
        self.weeks = file.load() ?? InboxZeroWeeks()
    }

    /// The inbox is empty now: counts this week. Writes only for a new week.
    public func record(email: String) {
        var next = weeks
        guard next.record(email: email, now: now()) else { return }
        weeks = next
        try? file.save(next)
    }

    /// Replaces every week (`make screenshots` seeds a streak).
    public func replace(with weeks: InboxZeroWeeks) {
        self.weeks = weeks
        try? file.save(weeks)
    }

    public func streak(email: String?, now: Date) -> Int {
        email.map { weeks.streak(email: $0, now: now) } ?? 0
    }
}

/// Inbox 0 texts.
public enum InboxZeroText {
    /// Over the streak number (shown in capitals).
    public static let streakTitle = "Inbox 0 -putki"

    /// Under the streak number: "viikko" for 1, else "viikkoa".
    public static func weeks(_ count: Int) -> String { count == 1 ? "viikko" : "viikkoa" }

    /// The streak's accessibility label: "Inbox 0 -putki: 3 viikkoa peräkkäin"
    public static func streakLabel(_ count: Int) -> String {
        "\(streakTitle): \(count) \(weeks(count)) peräkkäin"
    }
}
