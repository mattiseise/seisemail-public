import Foundation
import Testing
@testable import MailCore

@Suite struct SnoozeMenuModelTests {
    let N = D(1_791_018_000)                     // la 3.10.2026 12.00

    func model(now: Date? = nil, count: Int = 1, settings: SnoozePresetSettings = .standard) -> SnoozeMenuModel {
        SnoozeMenuModel(now: now ?? N, targetCount: count, settings: settings)
    }

    func titles(_ m: SnoozeMenuModel) -> [String] { m.entries.map(\.title) }
    func details(_ m: SnoozeMenuModel) -> [String] { m.entries.map(\.detail) }
    func wakes(_ m: SnoozeMenuModel) -> [Date?] { m.entries.map(\.wakeAt) }

    // MARK: - Entries

    @Test func standardEntries() {
        let m = model()
        #expect(titles(m) == ["Tänään illalla", "Huomenna", "Ensi viikolla", "Ensi kuussa", "Oma aika…"])
        #expect(m.entries.map(\.number) == [1, 2, 3, 4, 5])
        #expect(m.entries.map(\.id) == [1, 2, 3, 4, 5])
        #expect(m.entries.map(\.kind) == [.preset(.tonight), .preset(.tomorrow), .preset(.nextWeek), .preset(.nextMonth), .custom])
        #expect(wakes(m) == [D(1_791_046_800), D(1_791_090_000), D(1_791_176_400), D(1_793_512_800), nil])
        #expect(details(m) == ["la 3.10. klo 20.00", "su 4.10. klo 8.00", "ma 5.10. klo 8.00", "su 1.11. klo 8.00",
                               "Valitse päivä ja kellonaika"])
        #expect(m.entries.allSatisfy { $0.isEnabled })
        #expect(m.highlighted == 0)
        #expect(m.mode == .list)
        #expect(m.targetCount == 1)
        #expect(m.timeZone == SnoozePresets.helsinki)
    }

    @Test func eveningDimsTonightAndKeepsTheDigits() {
        let m = model(now: D(1_791_052_200))                                        // la 21.30
        #expect(titles(m) == ["Tänään illalla", "Huomenna", "Ensi viikolla", "Ensi kuussa", "Oma aika…"])
        #expect(m.entries.map(\.number) == [1, 2, 3, 4, 5])
        #expect(wakes(m) == [nil, D(1_791_090_000), D(1_791_176_400), D(1_793_512_800), nil])
        #expect(details(m) == ["Ei enää tänään", "su 4.10. klo 8.00", "ma 5.10. klo 8.00", "su 1.11. klo 8.00",
                               "Valitse päivä ja kellonaika"])
        #expect(m.entries.map(\.isEnabled) == [false, true, true, true, true])
        #expect(m.highlighted == 1)
    }

    @Test func atEightTonightIsGone() {
        let m = model(now: D(1_791_046_800))                                        // la 20.00
        #expect(m.entries[0].wakeAt == nil)
        let before = model(now: D(1_791_046_740))                                   // la 19.59
        #expect(before.entries[0].wakeAt == D(1_791_046_800))
        #expect(before.entries[0].detail == "la 3.10. klo 20.00")
    }

    @Test func sundayTomorrowAndNextWeekCoincide() {
        let m = model(now: D(1_791_104_400))                                        // su 4.10. 12.00
        #expect(wakes(m) == [D(1_791_133_200), D(1_791_176_400), D(1_791_176_400), D(1_793_512_800), nil])
        #expect(details(m) == ["su 4.10. klo 20.00", "ma 5.10. klo 8.00", "ma 5.10. klo 8.00", "su 1.11. klo 8.00",
                               "Valitse päivä ja kellonaika"])
    }

    @Test func onMondayNextWeekIsAWeekAway() {
        let m = model(now: D(1_791_172_800))                                        // ma 5.10. 7.00
        #expect(wakes(m) == [D(1_791_219_600), D(1_791_262_800), D(1_791_781_200), D(1_793_512_800), nil])
        #expect(details(m)[2] == "ma 12.10. klo 8.00")
    }

    @Test func onTheFirstNextMonthIsAMonthAway() {
        let m = model(now: D(1_790_827_200))                                        // to 1.10. 7.00
        #expect(wakes(m) == [D(1_790_874_000), D(1_790_917_200), D(1_791_176_400), D(1_793_512_800), nil])
        #expect(details(m)[3] == "su 1.11. klo 8.00")
    }

    @Test func yearShownAcrossNewYear() {
        let m = model(now: D(1_798_740_000))                                        // to 31.12. 20.00
        #expect(details(m) == ["Ei enää tänään", "pe 1.1.2027 klo 8.00", "ma 4.1.2027 klo 8.00", "pe 1.1.2027 klo 8.00",
                               "Valitse päivä ja kellonaika"])
        #expect(wakes(m) == [nil, D(1_798_783_200), D(1_799_042_400), D(1_798_783_200), nil])
    }

    @Test func springForwardSaturday() {
        let m = model(now: D(1_774_692_000))                                        // la 28.3. 12.00 (+02)
        #expect(wakes(m) == [D(1_774_720_800), D(1_774_760_400), D(1_774_846_800), D(1_775_019_600), nil])
        #expect(details(m) == ["la 28.3. klo 20.00", "su 29.3. klo 8.00", "ma 30.3. klo 8.00", "ke 1.4. klo 8.00",
                               "Valitse päivä ja kellonaika"])
    }

    @Test func autumnBackSaturday() {
        let m = model(now: D(1_792_832_400))                                        // la 24.10. 12.00 (+03)
        #expect(wakes(m) == [D(1_792_861_200), D(1_792_908_000), D(1_792_994_400), D(1_793_512_800), nil])
        #expect(details(m) == ["la 24.10. klo 20.00", "su 25.10. klo 8.00", "ma 26.10. klo 8.00", "su 1.11. klo 8.00",
                               "Valitse päivä ja kellonaika"])
    }

    @Test func autumnBackSundayNight() {
        let m = model(now: D(1_792_881_000))                                        // su 25.10. 1.30 (+03)
        #expect(m.entries[0].wakeAt == D(1_792_951_200))                            // su 20.00 (+02)
        #expect(m.entries[0].detail == "su 25.10. klo 20.00")
        #expect(m.entries[1].wakeAt == D(1_792_994_400))
        #expect(m.entries[2].wakeAt == D(1_792_994_400))
    }

    @Test func customStartsTomorrow() {
        #expect(model().customDate == D(1_791_090_000))
        #expect(model(now: D(1_798_740_000)).customDate == D(1_798_783_200))
    }

    // MARK: - Keys, list mode

    @Test func digitChooses() {
        let expected: [Int: Date] = [1: D(1_791_046_800), 2: D(1_791_090_000), 3: D(1_791_176_400), 4: D(1_793_512_800)]
        for (digit, wake) in expected {
            var m = model()
            #expect(m.handle(.digit(digit), now: N) == .snooze(wake), "digit \(digit)")
        }
        var custom = model()
        #expect(custom.handle(.digit(5), now: N) == .consumed)
        #expect(custom.mode == .custom)
    }

    @Test func digitOutOfRangeSwallowed() {
        var m = model()
        let before = m
        #expect(m.handle(.digit(9), now: N) == .consumed)
        #expect(m.handle(.digit(6), now: N) == .consumed)
        #expect(m.handle(.digit(0), now: N) == .consumed)
        #expect(m.mode == .list)
        #expect(m == before)
    }

    @Test func dimmedTonightIgnoresDigitAndMouse() {
        let evening = D(1_791_052_200)                                              // la 21.30
        var m = model(now: evening)
        let before = m
        #expect(m.handle(.digit(1), now: evening) == .consumed)
        #expect(m.choose(0) == .consumed)
        #expect(m == before)
        #expect(m.handle(.digit(2), now: evening) == .snooze(D(1_791_090_000)))
    }

    @Test func arrowsClamp() {
        var m = model()
        for _ in 0..<7 { #expect(m.handle(.down, now: N) == .consumed) }
        #expect(m.highlighted == 4)
        for _ in 0..<9 { #expect(m.handle(.up, now: N) == .consumed) }
        #expect(m.highlighted == 0)
        #expect(m.mode == .list)
    }

    @Test func arrowsSkipDimmedTonight() {
        let evening = D(1_791_052_200)
        var m = model(now: evening)
        #expect(m.handle(.up, now: evening) == .consumed)
        #expect(m.highlighted == 1)
        _ = m.handle(.down, now: evening)
        _ = m.handle(.up, now: evening)
        #expect(m.highlighted == 1)
        #expect(m.handle(.enter, now: evening) == .snooze(D(1_791_090_000)))
    }

    @Test func enterChoosesHighlighted() {
        var m = model()
        _ = m.handle(.down, now: N)
        #expect(m.handle(.enter, now: N) == .snooze(D(1_791_090_000)))
        var top = model()
        #expect(top.handle(.enter, now: N) == .snooze(D(1_791_046_800)))
    }

    @Test func enterOnCustomOpensIt() {
        var m = model()
        for _ in 0..<4 { _ = m.handle(.down, now: N) }
        #expect(m.handle(.enter, now: N) == .consumed)
        #expect(m.mode == .custom)
    }

    @Test func escapeCloses() {
        var m = model()
        #expect(m.handle(.escape, now: N) == .close)
    }

    @Test func otherSwallowed() {
        var m = model()
        let before = m
        #expect(m.handle(.other, now: N) == .consumed)
        #expect(m == before)
    }

    // MARK: - Custom mode

    @Test func customOpens() {
        var m = model()
        #expect(m.handle(.digit(5), now: N) == .consumed)
        #expect(m.mode == .custom)
        #expect(m.customDate == D(1_791_090_000))
    }

    @Test func customOtherKeysAreSwallowed() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        let before = m
        #expect(m.handle(.other, now: N) == .consumed)
        #expect(m == before)
        #expect(m.mode == .custom)
    }

    // MARK: - Calendar ("Oma aika")

    @Test func calendarStartsTomorrowAtEight() {
        let m = model()
        #expect(m.today == 20_729)                                                  // la 3.10.
        #expect(m.customDay == 20_730)                                              // su 4.10.
        #expect(m.customMinutes == 480)
        #expect(m.timeText == "8.00")
        #expect(m.shownMonth == 20_727)                                             // 1.10.
        #expect(m.monthTitle == "Lokakuu 2026")
        #expect(m.canShowPreviousMonth == false)
    }

    @Test func calendarGridOctober2026() {
        let weeks = model().calendarWeeks
        #expect(weeks.count == 6)
        #expect(weeks.map(\.number) == [40, 41, 42, 43, 44, 45])
        let cells = weeks.flatMap(\.cells)
        #expect(cells.count == 42)
        #expect(cells.first?.day == 20_724)                                         // ma 28.9.
        #expect(cells.first?.dayOfMonth == 28)
        #expect(cells.first?.inMonth == false)
        #expect(cells.filter(\.inMonth).map(\.dayOfMonth) == Array(1...31))
        #expect(cells.filter(\.isToday).map(\.day) == [20_729])
        #expect(cells.filter(\.isSelected).map(\.day) == [20_730])
        #expect(cells.filter(\.isPast).map(\.day) == Array(20_724...20_728))
        #expect(cells.first?.label == "ma 28.9.")
        #expect(cells.first(where: \.isToday)?.label == "la 3.10.")
    }

    @Test func isoWeekNumbersAcrossNewYear() {
        #expect(SnoozeMenuModel.isoWeek(monday: 20_451) == 1)                        // ma 29.12.2025
        #expect(SnoozeMenuModel.isoWeek(monday: 20_815) == 53)                       // ma 28.12.2026
        #expect(SnoozeMenuModel.isoWeek(monday: 20_822) == 1)                        // ma 4.1.2027
    }

    @Test func arrowsMoveTheDayNotBeforeToday() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        _ = m.handle(.right, now: N)
        #expect(m.customDay == 20_731)
        for _ in 0..<5 { _ = m.handle(.left, now: N) }
        #expect(m.customDay == 20_729)                                              // today, not before
        _ = m.handle(.up, now: N)
        #expect(m.customDay == 20_729)
        _ = m.handle(.right, now: N)
        for _ in 0..<4 { _ = m.handle(.down, now: N) }
        #expect(m.customDay == 20_758)                                              // su 1.11.
        #expect(m.monthTitle == "Marraskuu 2026")
        #expect(m.customMinutes == 480)                                             // the time stays
        #expect(m.customDate == D(1_793_512_800))
        #expect(m.mode == .custom)
    }

    @Test func digitsTypeTheTime() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        for d in [1, 4, 3, 0] { #expect(m.handle(.digit(d), now: N) == .consumed) }
        #expect(m.customField == .time)
        #expect(m.timeEntry == "1430")
        #expect(m.timeText == "14.30")
        #expect(m.customDate == D(1_791_113_400))                                   // su 4.10. 14.30
        _ = m.handle(.digit(9), now: N)                                              // a fifth digit starts over
        #expect(m.timeEntry == "9")
        #expect(m.timeText == "9.00")
        _ = m.handle(.backspace, now: N)
        #expect(m.timeEntry == "")
        #expect(m.timeText == "9.00")
    }

    @Test func backspaceErasesTheLastDigit() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        for d in [1, 4, 3, 0] { _ = m.handle(.digit(d), now: N) }
        _ = m.handle(.backspace, now: N)
        #expect(m.timeEntry == "143")
        #expect(m.timeText == "1.43")
    }

    @Test func parsesTypedTimes() {
        let cases: [(String, Int?)] = [
            ("0", 0), ("8", 480), ("14", 840), ("23", 1380), ("24", 160), ("83", 510), ("99", nil),
            ("830", 510), ("143", 103), ("960", nil), ("1430", 870), ("0905", 545), ("2400", nil), ("2360", nil), ("", nil),
        ]
        for (digits, minutes) in cases {
            #expect(SnoozeMenuModel.parseTime(digits) == minutes, "\(digits)")
        }
    }

    @Test func invalidDigitStartsANewEntry() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        _ = m.handle(.digit(9), now: N)
        _ = m.handle(.digit(9), now: N)                                              // "99" is no time: "9" again
        #expect(m.timeEntry == "9")
        #expect(m.timeText == "9.00")
    }

    @Test func arrowsStepTheTimeByQuarterHours() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        _ = m.handle(.tab, now: N)
        _ = m.handle(.up, now: N)
        #expect(m.timeText == "8.15")
        _ = m.handle(.down, now: N)
        _ = m.handle(.down, now: N)
        #expect(m.timeText == "7.45")
        for d in [8, 0, 7] { _ = m.handle(.digit(d), now: N) }
        _ = m.handle(.up, now: N)
        #expect(m.timeText == "8.15")
        #expect(m.timeEntry == "")
        for d in [8, 0, 7] { _ = m.handle(.digit(d), now: N) }
        _ = m.handle(.down, now: N)
        #expect(m.timeText == "8.00")
        for _ in 0..<100 { _ = m.handle(.up, now: N) }
        #expect(m.timeText == "23.45")
        for _ in 0..<100 { _ = m.handle(.down, now: N) }
        #expect(m.timeText == "0.00")
        #expect(m.customDay == 20_730)                                              // the day stays
    }

    @Test func leftAndRightDoNothingInTheTime() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        _ = m.handle(.tab, now: N)
        let before = m
        _ = m.handle(.left, now: N)
        _ = m.handle(.right, now: N)
        #expect(m == before)
    }

    @Test func monthArrowsChangeOnlyTheShownMonth() {
        var m = model()
        m.showMonth(by: -1)
        #expect(m.monthTitle == "Lokakuu 2026")                                     // not before today's month
        m.showMonth(by: 1)
        #expect(m.monthTitle == "Marraskuu 2026")
        #expect(m.canShowPreviousMonth)
        m.showMonth(by: 2)
        #expect(m.monthTitle == "Tammikuu 2027")
        m.showMonth(by: -1)
        #expect(m.monthTitle == "Joulukuu 2026")
        #expect(m.customDay == 20_730)
    }

    @Test func clickingDaysAndChips() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        _ = m.handle(.tab, now: N)
        m.selectDay(20_728)                                                          // yesterday: ignored
        #expect(m.customDay == 20_730)
        #expect(m.customField == .time)
        m.selectDay(20_742)                                                          // pe 16.10.
        #expect(m.customDay == 20_742)
        #expect(m.customField == .day)
        m.setTime(minutes: 20 * 60)
        #expect(m.timeText == "20.00")
        #expect(SnoozeMenuModel.timeChoices.map { String(format: "%d.%02d", $0 / 60, $0 % 60) } == ["8.00", "12.00", "16.00", "20.00"])
        #expect(m.handle(.enter, now: N) == .snooze(D(1_792_126_800 + 12 * 3600)))  // pe 16.10. 20.00
    }

    @Test func escapeClearsTheTypedTime() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        _ = m.handle(.digit(1), now: N)
        _ = m.handle(.escape, now: N)
        #expect(m.mode == .list)
        #expect(m.timeEntry == "")
    }

    @Test func tabSwitchesBetweenCalendarAndTime() {
        var m = model()
        #expect(m.handle(.tab, now: N) == .consumed)                               // list: swallowed
        #expect(m.mode == .list)
        _ = m.handle(.digit(5), now: N)
        #expect(m.customField == .day)
        #expect(m.handle(.tab, now: N) == .consumed)
        #expect(m.customField == .time)
        #expect(m.handle(.tab, now: N) == .consumed)
        #expect(m.customField == .day)
        _ = m.handle(.tab, now: N)
        _ = m.handle(.escape, now: N)
        _ = m.handle(.digit(5), now: N)                                             // reopened: the calendar again
        #expect(m.customField == .day)
    }

    @Test func customEnterDefaultIsTomorrow() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        #expect(m.handle(.enter, now: N) == .snooze(D(1_791_090_000)))
    }

    @Test func customEnterValid() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        m.customDate = D(1_791_262_800)
        #expect(m.customCheck(now: N) == .ok(D(1_791_262_800)))
        #expect(m.handle(.enter, now: N) == .snooze(D(1_791_262_800)))
    }

    @Test func customDateKeepsWholeMinutes() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        m.customDate = N.addingTimeInterval(90)                                     // 12.01.30 → 12.01
        #expect(m.customDate == D(1_791_018_060))
        #expect(m.customDay == 20_729)
        #expect(m.shownMonth == 20_727)
        #expect(m.handle(.enter, now: N) == .snooze(D(1_791_018_060)))
    }

    @Test func customCheckUsesGivenNow() {
        var m = model()
        m.customDate = N.addingTimeInterval(60)
        #expect(m.customCheck(now: N.addingTimeInterval(59)) == .ok(N.addingTimeInterval(60)))
        #expect(m.customCheck(now: N.addingTimeInterval(60)) == .notInFuture)
    }

    @Test func customPastStaysOpen() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        m.customDate = N.addingTimeInterval(-60)
        #expect(m.customCheck(now: N) == .notInFuture)
        #expect(m.handle(.enter, now: N) == .consumed)
        #expect(m.mode == .custom)
        #expect(m.customPreview(now: N) == "Torkutusaika on jo mennyt")
    }

    @Test func customNowIsNotFuture() {
        var m = model()
        m.customDate = N
        #expect(m.customCheck(now: N) == .notInFuture)
        m.customDate = N.addingTimeInterval(-30)                                    // 11.59
        #expect(m.customCheck(now: N) == .notInFuture)
    }

    @Test func customOutOfRange() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        m.customDate = SnoozeTime.latest.addingTimeInterval(60)
        #expect(m.customCheck(now: N) == .outOfRange)
        #expect(m.customPreview(now: N) == "Torkutusaika ei kelpaa")
        #expect(m.handle(.enter, now: N) == .consumed)
        #expect(m.mode == .custom)
        m.customDate = SnoozeTime.latest
        #expect(m.customCheck(now: N) == .ok(SnoozeTime.latest))
    }

    @Test func customEscapeBack() {
        var m = model()
        _ = m.handle(.digit(5), now: N)
        #expect(m.handle(.escape, now: N) == .consumed)
        #expect(m.mode == .list)
        #expect(m.handle(.escape, now: N) == .close)
    }

    @Test func customPreviewText() {
        var m = model()
        m.customDate = D(1_791_262_800)
        #expect(m.customPreview(now: N) == "Herää ti 6.10. klo 8.00")
        m.customDate = D(1_799_128_800)
        #expect(m.customPreview(now: N) == "Herää ti 5.1.2027 klo 8.00")
    }

    // MARK: - Text and mouse

    @Test func titleAndFooter() {
        #expect(model(count: 1).title == "Torkuta")
        #expect(model(count: 2).title == "Torkuta · 2 valittua")
        #expect(model(count: 3).title == "Torkuta · 3 valittua")
        #expect(model(count: 3).targetCount == 3)
        var m = model()
        #expect(m.footer == "Valitse numerolla 1–5 tai ↑↓ ja ↩ · Esc\u{A0}sulkee")
        _ = m.handle(.digit(5), now: N)
        #expect(m.footer == "Nuolet vaihtavat päivää · numerot asettavat kellonajan · ↩\u{A0}torkuttaa · Esc\u{A0}palaa listaan")
        _ = m.handle(.tab, now: N)
        #expect(m.footer == "Kirjoita aika (esim. 1430) tai ↑↓\u{A0}15\u{A0}min · Tab\u{A0}kalenteriin · ↩\u{A0}torkuttaa · Esc\u{A0}palaa listaan")
    }

    @Test func mouseMatchesDigit() {
        var byMouse = model()
        var byKey = model()
        #expect(byMouse.choose(0) == byKey.handle(.digit(1), now: N))
        #expect(byMouse.choose(0) == .snooze(D(1_791_046_800)))
        var customMouse = model()
        var customKey = model()
        #expect(customMouse.choose(4) == .consumed)
        #expect(customKey.handle(.digit(5), now: N) == .consumed)
        #expect(customMouse == customKey)
        #expect(customMouse.mode == .custom)
    }
}
