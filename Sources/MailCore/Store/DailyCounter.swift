import Foundation
import Observation

/// Archived and snoozed thread counts: a day's totals, or one change to them (negative when undone).
public struct ActivityCounts: Sendable, Equatable {
    public var archived: Int
    public var snoozed: Int

    public init(archived: Int = 0, snoozed: Int = 0) {
        self.archived = archived
        self.snoozed = snoozed
    }

    public static let zero = ActivityCounts()

    public var negated: ActivityCounts { ActivityCounts(archived: -archived, snoozed: -snoozed) }

    public static func + (a: ActivityCounts, b: ActivityCounts) -> ActivityCounts {
        ActivityCounts(archived: a.archived + b.archived, snoozed: a.snoozed + b.snoozed)
    }
}

/// Today's counts (conventions §3): device-local, not synced, reset at Helsinki midnight.
public struct DailyCounter: Codable, Sendable, Equatable {
    /// Helsinki civil day of the last change (CivilTime.localDay).
    public private(set) var day = 0
    public private(set) var archived = 0
    public private(set) var snoozed = 0

    public init() {}

    private enum CodingKeys: String, CodingKey { case day, archived, snoozed }

    /// Per field lenient, like AppSettings: a missing or invalid field keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = c.lenient(.day) ?? 0
        archived = c.lenient(.archived) ?? 0
        snoozed = c.lenient(.snoozed) ?? 0
    }

    /// Starts a new day when needed, then adds; each count clamped at 0.
    public mutating func apply(_ delta: ActivityCounts, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) {
        let today = CivilTime.localDay(of: now, in: timeZone)
        if today != day {
            day = today
            archived = 0
            snoozed = 0
        }
        archived = max(0, archived + delta.archived)
        snoozed = max(0, snoozed + delta.snoozed)
    }

    /// .zero when `now` is on another day.
    public func counts(now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> ActivityCounts {
        CivilTime.localDay(of: now, in: timeZone) == day ? ActivityCounts(archived: archived, snoozed: snoozed) : .zero
    }
}

/// The device's daily counter in `seise-today.json`; never synced (conventions §0).
@MainActor @Observable
public final class DailyCounterStore {
    public nonisolated static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("seise-today.json")
    }

    public private(set) var counter: DailyCounter
    @ObservationIgnored private let file: SettingsFile<DailyCounter>
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(file: SettingsFile<DailyCounter>, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
        self.counter = file.load() ?? DailyCounter()
    }

    /// No-op for .zero; writes only when the value changed.
    public func record(_ delta: ActivityCounts) {
        guard delta != .zero else { return }
        var next = counter
        next.apply(delta, now: now())
        guard next != counter else { return }
        counter = next
        try? file.save(next)
    }

    public func counts(now: Date) -> ActivityCounts {
        counter.counts(now: now)
    }
}
