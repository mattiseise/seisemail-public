import Foundation

/// Groups a newest-first thread list under relative date headings, like Notion Mail.
public enum ThreadGrouping {
    public struct Group: Identifiable, Sendable {
        public var id: String { title }
        public var title: String
        public var threads: [ThreadSummary]
    }

    private static let months = ["Tammikuu", "Helmikuu", "Maaliskuu", "Huhtikuu", "Toukokuu", "Kesäkuu",
                                 "Heinäkuu", "Elokuu", "Syyskuu", "Lokakuu", "Marraskuu", "Joulukuu"]

    public static func groups(_ threads: [ThreadSummary], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        var result: [Group] = []
        for thread in threads {
            let title = heading(for: thread.date, now: now, calendar: calendar)
            if result.last?.title == title {
                result[result.count - 1].threads.append(thread)
            } else {
                result.append(Group(title: title, threads: [thread]))
            }
        }
        return result
    }

    static func heading(for date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Tänään" }
        if days == 1 { return "Eilen" }
        if days < 7 { return "Viimeiset 7 päivää" }
        let d = calendar.dateComponents([.year, .month], from: date)
        let n = calendar.dateComponents([.year, .month], from: now)
        if d.year == n.year, d.month == n.month { return "Aiemmin tässä kuussa" }
        let month = months[(d.month ?? 1) - 1]
        return d.year == n.year ? month : "\(month) \(d.year ?? 0)"
    }
}
