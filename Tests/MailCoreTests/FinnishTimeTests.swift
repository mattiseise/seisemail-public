import Foundation
import Testing
@testable import MailCore

/// Every instant and expected string was computed with Python zoneinfo (Europe/Helsinki).
@Suite struct FinnishTimeTests {
    let N = D(1_791_018_000)                     // la 3.10.2026 12.00 (+03)
    let utc = TimeZone(identifier: "UTC")!

    @Test func weekdaysAreISOOrder() {
        #expect(FinnishTime.weekdays == ["ma", "ti", "ke", "to", "pe", "la", "su"])
    }

    @Test func clock() {
        #expect(FinnishTime.clock(D(1_791_176_400)) == "8.00")              // ma 5.10. 8.00
        #expect(FinnishTime.clock(D(1_791_029_100)) == "15.05")
        #expect(FinnishTime.clock(D(1_791_061_200)) == "0.00")              // su 4.10. 0.00
        #expect(FinnishTime.clock(D(1_791_061_140)) == "23.59")
        #expect(FinnishTime.clock(D(1_791_176_400), timeZone: utc) == "5.00")
    }

    // MARK: - full

    @Test func fullSameYear() {
        #expect(FinnishTime.full(D(1_791_176_400), now: N) == "ma 5.10. klo 8.00")
    }

    @Test func fullPadsMinutes() {
        #expect(FinnishTime.full(D(1_791_029_100), now: N) == "la 3.10. klo 15.05")
    }

    @Test func fullOtherYear() {
        #expect(FinnishTime.full(D(1_799_128_800), now: N) == "ti 5.1.2027 klo 8.00")
        #expect(FinnishTime.full(D(1_798_783_200), now: N) == "pe 1.1.2027 klo 8.00")
        // An earlier year relative to now gets its year too.
        #expect(FinnishTime.full(D(1_798_740_000), now: D(1_799_128_800)) == "to 31.12.2026 klo 20.00")
    }

    // MARK: - dateAndClock ("since" lines: always the date, never "tänään")

    @Test func dateAndClock() {
        #expect(FinnishTime.dateAndClock(D(1_791_176_400), now: N) == "5.10. klo 8.00")
        #expect(FinnishTime.dateAndClock(D(1_791_029_100), now: N) == "3.10. klo 15.05")   // the same day as now
        #expect(FinnishTime.dateAndClock(D(1_799_128_800), now: N) == "5.1.2027 klo 8.00")
        #expect(FinnishTime.dateAndClock(D(1_791_149_400), now: N) == "5.10. klo 0.30")    // UTC is still 4.10.
    }

    @Test func fullAfterDSTEnd() {
        #expect(FinnishTime.full(D(1_792_994_400), now: N) == "ma 26.10. klo 8.00")       // +02
        #expect(FinnishTime.full(D(1_792_908_000), now: N) == "su 25.10. klo 8.00")       // the 25-hour day
        #expect(FinnishTime.full(D(1_792_875_600), now: N) == "su 25.10. klo 0.00")
        #expect(FinnishTime.full(D(1_792_965_540), now: N) == "su 25.10. klo 23.59")
    }

    @Test func repeatedHourAtDSTEnd() {
        // 03.30 happens twice on 25.10.2026: 00:30Z (+03) and 01:30Z (+02).
        #expect(FinnishTime.full(D(1_792_888_200), now: N) == "su 25.10. klo 3.30")
        #expect(FinnishTime.full(D(1_792_891_800), now: N) == "su 25.10. klo 3.30")
    }

    @Test func springForwardDay() {
        // 29.3.2026: 02.59 (+02) is followed by 04.00 (+03); the 23-hour day.
        #expect(FinnishTime.full(D(1_774_735_200), now: N) == "su 29.3. klo 0.00")
        #expect(FinnishTime.full(D(1_774_745_940), now: N) == "su 29.3. klo 2.59")
        #expect(FinnishTime.full(D(1_774_746_000), now: N) == "su 29.3. klo 4.00")
        #expect(FinnishTime.full(D(1_774_817_940), now: N) == "su 29.3. klo 23.59")
        #expect(FinnishTime.full(D(1_774_818_000), now: N) == "ma 30.3. klo 0.00")
    }

    @Test func defaultIgnoresSystemZone() {
        #expect(FinnishTime.full(D(1_791_176_400), now: N, timeZone: utc) == "ma 5.10. klo 5.00")
        #expect(FinnishTime.full(D(1_791_176_400), now: N) == "ma 5.10. klo 8.00")
        #expect(FinnishTime.full(D(1_791_176_400), now: N, timeZone: SnoozePresets.helsinki) == "ma 5.10. klo 8.00")
    }

    // MARK: - compact

    @Test func compactBuckets() {
        let now = D(1_791_529_200)                                          // pe 9.10. 10.00
        #expect(FinnishTime.compact(D(1_791_543_900), now: now) == "tänään 14.05")
        #expect(FinnishTime.compact(D(1_791_608_400), now: now) == "huomenna 8.00")
        #expect(FinnishTime.compact(D(1_791_781_200), now: now) == "ma 8.00")
    }

    @Test func compactFromSaturday() {
        #expect(FinnishTime.compact(D(1_791_029_100), now: N) == "tänään 15.05")
        #expect(FinnishTime.compact(D(1_791_090_000), now: N) == "huomenna 8.00")
        #expect(FinnishTime.compact(D(1_791_176_400), now: N) == "ma 8.00")          // 2 days
        #expect(FinnishTime.compact(D(1_791_522_000), now: N) == "pe 8.00")          // 6 days
        #expect(FinnishTime.compact(D(1_791_608_400), now: N) == "10.10. klo 8.00")  // 7 days
        #expect(FinnishTime.compact(D(1_791_781_200), now: N) == "12.10. klo 8.00")
        #expect(FinnishTime.compact(D(1_799_042_400), now: N) == "4.1.2027 klo 8.00")
    }

    @Test func compactAcrossMidnight() {
        #expect(FinnishTime.compact(D(1_791_063_000), now: D(1_791_061_140)) == "huomenna 0.30")
    }

    @Test func compactAcrossDST() {
        #expect(FinnishTime.compact(D(1_792_908_000), now: D(1_792_832_400)) == "huomenna 8.00")   // autumn
        #expect(FinnishTime.compact(D(1_774_760_400), now: D(1_774_692_000)) == "huomenna 8.00")   // spring: la 28.3. 12.00 → su 29.3. 8.00
        #expect(FinnishTime.compact(D(1_774_846_800), now: D(1_774_692_000)) == "ma 8.00")
    }

    @Test func compactWeekdayAcrossNewYear() {
        let now = D(1_798_740_000)                                          // to 31.12.2026 20.00
        #expect(FinnishTime.compact(D(1_798_783_200), now: now) == "huomenna 8.00")
        #expect(FinnishTime.compact(D(1_799_042_400), now: now) == "ma 8.00")        // 4 civil days: weekday form
        #expect(FinnishTime.compact(D(1_799_128_800), now: now) == "ti 8.00")
        #expect(FinnishTime.compact(D(1_799_128_800), now: N) == "5.1.2027 klo 8.00")
    }

    @Test func compactUsesGivenZone() {
        // su 4.10. 0.00 in Helsinki is Saturday 21.00 UTC; now N is Saturday in both zones.
        #expect(FinnishTime.compact(D(1_791_061_200), now: N) == "huomenna 0.00")
        #expect(FinnishTime.compact(D(1_791_061_200), now: N, timeZone: utc) == "tänään 21.00")
    }
}
