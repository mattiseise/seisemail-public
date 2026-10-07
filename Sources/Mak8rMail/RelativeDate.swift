import Foundation

/// List dates: time today, day and month this year, full date before that.
enum RelativeDate {
    static func format(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: "%d.%02d", c.hour ?? 0, c.minute ?? 0)
        }
        if calendar.component(.year, from: now) == c.year {
            return "\(c.day ?? 0).\(c.month ?? 0)."
        }
        return "\(c.day ?? 0).\(c.month ?? 0).\(c.year ?? 0)"
    }
}
