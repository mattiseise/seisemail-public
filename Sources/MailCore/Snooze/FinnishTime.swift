import Foundation

/// Finnish date/time text in a fixed zone (Helsinki by default), independent of the system locale and zone.
public enum FinnishTime {
    public static let weekdays = ["ma", "ti", "ke", "to", "pe", "la", "su"]   // ISO 1…7

    struct Parts { var day, year, month, dayOfMonth, weekday, hour, minute: Int }

    static func parts(_ date: Date, _ zone: TimeZone) -> Parts {
        let t = Int(date.timeIntervalSince1970.rounded(.down))
        let local = t + CivilTime.offset(zone, atEpochSeconds: t)
        let day = CivilTime.floorDiv(local, 86_400)
        let minuteOfDay = (local - day * 86_400) / 60
        let (y, m, d) = CivilTime.civil(days: day)
        return Parts(day: day, year: y, month: m, dayOfMonth: d, weekday: CivilTime.isoWeekday(days: day),
                     hour: minuteOfDay / 60, minute: minuteOfDay % 60)
    }

    /// "8.00", "14.05"
    public static func clock(_ date: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        clock(parts(date, timeZone))
    }

    /// "ma 5.10. klo 8.00"; when the year differs from `now`'s: "ti 5.1.2027 klo 8.00"
    public static func full(_ date: Date, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        let p = parts(date, timeZone)
        let sameYear = p.year == parts(now, timeZone).year
        return weekday(p) + " " + dayMonth(p, withYear: !sameYear) + " klo " + clock(p)
    }

    /// Civil-day distance from `now`: 0 "tänään 15.05", 1 "huomenna 8.00", 2…6 "ma 8.00",
    /// otherwise "10.10. klo 8.00", or "5.1.2027 klo 8.00" in another year.
    public static func compact(_ date: Date, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        let p = parts(date, timeZone)
        let n = parts(now, timeZone)
        switch p.day - n.day {
        case 0: return "tänään " + clock(p)
        case 1: return "huomenna " + clock(p)
        case 2...6: return weekday(p) + " " + clock(p)
        default: return dayMonth(p, withYear: p.year != n.year) + " klo " + clock(p)
        }
    }

    /// Always the date, never "tänään": "5.10. klo 14.02"; in another year than `now`'s: "5.1.2027 klo 8.00"
    public static func dateAndClock(_ date: Date, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        let p = parts(date, timeZone)
        return dayMonth(p, withYear: p.year != parts(now, timeZone).year) + " klo " + clock(p)
    }

    private static func clock(_ p: Parts) -> String {
        String(format: "%d.%02d", p.hour, p.minute)
    }

    private static func weekday(_ p: Parts) -> String {
        weekdays[p.weekday - 1]
    }

    /// "5.10." or "5.1.2027"
    private static func dayMonth(_ p: Parts, withYear: Bool) -> String {
        withYear ? "\(p.dayOfMonth).\(p.month).\(p.year)" : "\(p.dayOfMonth).\(p.month)."
    }
}
