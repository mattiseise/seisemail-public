import Foundation
import Testing
@testable import MailCore

@Suite struct ThreadGroupingTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }

    // Wed 23.9.2026 17:00 Helsinki
    let now = Date(timeIntervalSince1970: 1_790_172_000)

    func summary(_ id: String, daysAgo: Double, hour: Double = 0) -> ThreadSummary {
        ThreadSummary(id: id, subject: id, sender: id, snippet: "", date: now.addingTimeInterval(-daysAgo * 86_400 - hour * 3600),
                      labelIDs: [], hasAttachments: false, messageCount: 1)
    }

    @Test func groupsByRelativeDay() {
        let threads = [
            summary("today", daysAgo: 0, hour: 1),
            summary("yesterday", daysAgo: 1),
            summary("week", daysAgo: 4),
            summary("month", daysAgo: 12),
            summary("august", daysAgo: 30),
            summary("august2", daysAgo: 40),
            summary("2025", daysAgo: 300),
        ]
        let groups = ThreadGrouping.groups(threads, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Tänään", "Eilen", "Viimeiset 7 päivää", "Aiemmin tässä kuussa", "Elokuu", "Marraskuu 2025"])
        #expect(groups.map { $0.threads.map(\.id) } == [["today"], ["yesterday"], ["week"], ["month"], ["august", "august2"], ["2025"]])
    }

    @Test func emptyInputGivesNoGroups() {
        #expect(ThreadGrouping.groups([], now: now, calendar: calendar).isEmpty)
    }

    @Test func groupsAreStableIdentifiers() {
        let groups = ThreadGrouping.groups([summary("a", daysAgo: 0)], now: now, calendar: calendar)
        #expect(groups.first?.id == "Tänään")
    }
}
