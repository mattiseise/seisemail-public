import Foundation

/// Matti's presets (7.10.2026), in menu order.
public enum SnoozePreset: String, Sendable, CaseIterable {
    case tonight, tomorrow, nextWeek, nextMonth

    public var title: String {
        switch self {
        case .tonight: "Tänään illalla"
        case .tomorrow: "Huomenna"
        case .nextWeek: "Ensi viikolla"
        case .nextMonth: "Ensi kuussa"
        }
    }
}

public struct SnoozePresetSettings: Sendable, Equatable, Codable {
    /// "Tänään illalla", 0...23; out-of-range values are clamped.
    public var eveningHour: Int
    /// The other presets, 0...23; out-of-range values are clamped.
    public var morningHour: Int
    /// 0...59; out-of-range values are clamped.
    public var morningMinute: Int

    public init(eveningHour: Int = 20, morningHour: Int = 8, morningMinute: Int = 0) {
        self.eveningHour = eveningHour
        self.morningHour = morningHour
        self.morningMinute = morningMinute
    }

    public static let standard = SnoozePresetSettings()
}

/// Snooze presets in local civil time (conventions §1 "Ajat ja pikavalinnat").
public enum SnoozePresets {
    public static let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    /// Later than `now` and on a whole minute; nil only for "Tänään illalla" once this evening's time has come.
    /// - tonight: today at the evening hour
    /// - tomorrow: the next civil day at the morning time, also just after midnight (Q3)
    /// - nextWeek: the next Monday at the morning time (on a Monday: a week later)
    /// - nextMonth: the 1st of the next month at the morning time (on the 1st: a month later)
    public static func date(for preset: SnoozePreset, now: Date,
                            timeZone: TimeZone = helsinki, settings: SnoozePresetSettings = .standard) -> Date? {
        let today = CivilTime.localDay(of: now, in: timeZone)
        func at(_ day: Int, hour: Int, minute: Int) -> Date {
            let (year, month, dayOfMonth) = CivilTime.civil(days: day)
            // Valid components never give nil.
            return CivilTime.instant(year: year, month: month, day: dayOfMonth,
                                     hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), in: timeZone)!
        }
        func morning(_ day: Int) -> Date { at(day, hour: settings.morningHour, minute: settings.morningMinute) }
        let result: Date
        switch preset {
        case .tonight:
            let evening = SnoozeTime.ceilToMinute(at(today, hour: settings.eveningHour, minute: 0))
            return evening > now ? evening : nil
        case .tomorrow:
            result = morning(today + 1)
        case .nextWeek:
            result = morning(today + 8 - CivilTime.isoWeekday(days: today))       // Mon → +7, Tue → +6, …, Sun → +1
        case .nextMonth:
            let (year, month, _) = CivilTime.civil(days: today)
            result = morning(CivilTime.days(year: month == 12 ? year + 1 : year, month: month % 12 + 1, day: 1))
        }
        return SnoozeTime.ceilToMinute(result)
    }
}
