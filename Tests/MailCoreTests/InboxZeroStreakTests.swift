import Foundation
import Testing
@testable import MailCore

@Suite struct InboxZeroStreakTests {
    // ke 7.10.2026 12.00 Helsinki; that week's Monday is 5.10. (day 20 731).
    let wed = D(1_791_363_600)
    let week: TimeInterval = 7 * 86_400

    @Test func mondayOfAnyDayInTheWeek() {
        for day in 20_731...20_737 { #expect(InboxZeroWeeks.monday(of: day) == 20_731, "day \(day)") }   // ma 5.10. … su 11.10.
        #expect(InboxZeroWeeks.monday(of: 20_738) == 20_738)                                         // ma 12.10.
    }

    @Test func recordsEachWeekOnce() {
        var w = InboxZeroWeeks()
        let first = w.record(email: "Matti@Example.com", now: wed)
        let again = w.record(email: "matti@example.com", now: wed.addingTimeInterval(86_400))         // same week
        #expect(first)
        #expect(again == false)
        #expect(w.mondays == ["matti@example.com": [20_731]])
    }

    @Test func streakCountsConsecutiveWeeks() {
        var w = InboxZeroWeeks()
        for back in [0, 1, 2, 4] { w.record(email: "m@x", now: wed.addingTimeInterval(-Double(back) * week)) }
        #expect(w.streak(email: "m@x", now: wed) == 3)                                               // the gap 4 weeks back
        #expect(w.streak(email: "other@x", now: wed) == 0)
    }

    @Test func thisWeekWithoutInboxZeroKeepsLastWeeksStreak() {
        var w = InboxZeroWeeks()
        w.record(email: "m@x", now: wed.addingTimeInterval(-week))
        w.record(email: "m@x", now: wed.addingTimeInterval(-2 * week))
        #expect(w.streak(email: "m@x", now: wed) == 2)                                               // week not over yet
        #expect(w.streak(email: "m@x", now: wed.addingTimeInterval(week)) == 0)                      // a whole week missed
    }

    @Test func weekChangesAtHelsinkiMidnightOnMonday() {
        var w = InboxZeroWeeks()
        let sundayLate = D(1_791_752_340)                                                            // su 11.10. 23.59
        let mondayEarly = D(1_791_752_460)                                                           // ma 12.10. 0.01
        w.record(email: "m@x", now: sundayLate)
        w.record(email: "m@x", now: mondayEarly)
        #expect(w.mondays["m@x"] == [20_731, 20_738])
        #expect(w.streak(email: "m@x", now: mondayEarly) == 2)
    }

    @MainActor @Test func storeWritesOnlyNewWeeksAndReloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("streak-\(UUID().uuidString).json")
        let clock = TestClock(wed)
        do {
            let store = InboxZeroStreakStore(file: SettingsFile(fileURL: url), now: clock.closure)
            store.record(email: "m@x")
            let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            store.record(email: "m@x")
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == written)
            clock.advance(by: week)
            store.record(email: "m@x")
            #expect(store.streak(email: "m@x", now: clock.now) == 2)
            #expect(store.streak(email: nil, now: clock.now) == 0)
            let reloaded = InboxZeroStreakStore(file: SettingsFile(fileURL: url), now: clock.closure)
            #expect(reloaded.weeks == store.weeks)
        }
    }

    @Test func texts() {
        #expect(InboxZeroText.weeks(1) == "viikko")
        #expect(InboxZeroText.weeks(52) == "viikkoa")
        #expect(InboxZeroText.streakLabel(3) == "Inbox 0 -putki: 3 viikkoa peräkkäin")
    }
}
