import Foundation

/// The `Torkku/<aika>` stamp: `yyyyMMdd'T'HHmm'Z'` in UTC (conventions §1). Hand-written ASCII parsing, no Regex:
/// Swift's `\d` matches any Unicode digit, JS's only 0–9.
public enum SnoozeTime {
    /// 9999-12-31T23:59:00Z, the last encodable minute.
    public static let latest = Date(timeIntervalSince1970: 253_402_300_740)

    /// Smallest whole-minute Date ≥ `date`. TS: `Math.ceil(ms / 60000) * 60000`.
    public static func ceilToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.up) * 60)
    }

    /// The stamp of `ceilToMinute(date)`. Precondition: year 1970...9999.
    public static func encode(_ date: Date) -> String {
        let seconds = Int(ceilToMinute(date).timeIntervalSince1970)
        let day = CivilTime.floorDiv(seconds, 86_400)
        let minuteOfDay = (seconds - day * 86_400) / 60
        let (year, month, dayOfMonth) = CivilTime.civil(days: day)
        precondition((1970...9999).contains(year), "Snooze time out of range: \(date)")
        return pad(year, 4) + pad(month, 2) + pad(dayOfMonth, 2) + "T" + pad(minuteOfDay / 60, 2) + pad(minuteOfDay % 60, 2) + "Z"
    }

    /// Inverse of `encode`; nil unless the stamp is exactly 14 ASCII bytes in that format and a real UTC minute
    /// with year ≥ 1970.
    public static func decode(_ stamp: String) -> Date? {
        decode(utf8: Array(stamp.utf8))
    }

    static func decode(utf8 bytes: [UInt8]) -> Date? {
        guard bytes.count == 14, bytes[8] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: "Z") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13),
              year >= 1970, (1...12).contains(month), (1...CivilTime.daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let seconds = CivilTime.days(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
