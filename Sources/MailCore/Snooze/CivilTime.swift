import Foundation

/// Integer civil-date and zone math (H. Hinnant's algorithms). The only time-zone primitive is the UTC offset at an
/// instant, so the TS port can mirror this file line by line with an Intl-based offset function.
enum CivilTime {
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Days since 1970-01-01 (days_from_civil).
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400                                             // 0...399
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1  // 0...365
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                     // 0...146096
        return era * 146_097 + doe - 719_468
    }

    /// Inverse of `days` (civil_from_days).
    static func civil(days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// 1 = Monday … 7 = Sunday. Day 0 (1970-01-01) is a Thursday.
    static func isoWeekday(days: Int) -> Int {
        ((days % 7 + 7) % 7 + 3) % 7 + 1
    }

    static func offset(_ zone: TimeZone, atEpochSeconds epochSeconds: Int) -> Int {
        zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    /// The local calendar day of `instant`, as days since 1970-01-01.
    static func localDay(of instant: Date, in zone: TimeZone) -> Int {
        let t = Int(instant.timeIntervalSince1970.rounded(.down))
        return floorDiv(t + offset(zone, atEpochSeconds: t), 86_400)
    }

    /// Local wall time → instant; nil for invalid components. In a spring gap the time moves forward by the gap
    /// length; in an autumn overlap the earlier instant wins (Temporal's "compatible").
    static func instant(year: Int, month: Int, day: Int, hour: Int, minute: Int, in zone: TimeZone) -> Date? {
        guard (1...12).contains(month), (1...daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        // The wall time read as if it were UTC.
        let naive = days(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60
        let offBefore = offset(zone, atEpochSeconds: naive - 86_400)
        let offAfter = offset(zone, atEpochSeconds: naive + 86_400)
        let c1 = naive - offBefore
        let c2 = naive - offAfter
        let seconds = switch (offset(zone, atEpochSeconds: c1) == offBefore, offset(zone, atEpochSeconds: c2) == offAfter) {
        case (true, true): min(c1, c2)      // equal outside transitions; the earlier one in an overlap
        case (true, false): c1
        case (false, true): c2
        case (false, false): c1             // gap: moves forward by the gap length
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
