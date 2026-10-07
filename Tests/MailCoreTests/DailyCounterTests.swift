import Foundation
import Testing
@testable import MailCore

/// Civil days and instants checked with Python zoneinfo (Europe/Helsinki).
@Suite struct DailyCounterTests {
    let N = D(1_791_018_000)                     // la 3.10.2026 12.00 (+03), Helsinki day 20729

    func counts(_ archived: Int, _ snoozed: Int) -> ActivityCounts {
        ActivityCounts(archived: archived, snoozed: snoozed)
    }

    // MARK: - ActivityCounts

    @Test func activityArithmetic() {
        #expect(ActivityCounts.zero == counts(0, 0))
        #expect(ActivityCounts() == .zero)
        #expect(ActivityCounts(archived: 2) == counts(2, 0))
        #expect(ActivityCounts(snoozed: 3) == counts(0, 3))
        #expect(counts(2, 1) + counts(1, 4) == counts(3, 5))
        #expect(counts(2, 1).negated == counts(-2, -1))
        #expect(counts(2, 1) + counts(2, 1).negated == .zero)
    }

    // MARK: - DailyCounter

    @Test func startsZero() {
        let c = DailyCounter()
        #expect(c.counts(now: N) == .zero)
        #expect(c.day == 0 && c.archived == 0 && c.snoozed == 0)
    }

    @Test func adds() {
        var c = DailyCounter()
        c.apply(counts(2, 0), now: N)
        c.apply(counts(0, 1), now: N)
        #expect(c.counts(now: N) == counts(2, 1))
        #expect(c.archived == 2)
        #expect(c.snoozed == 1)
        #expect(c.day == 20729)
    }

    @Test func resetsAtHelsinkiMidnight() {
        var c = DailyCounter()
        c.apply(counts(1, 0), now: D(1_791_061_140))                        // la 23.59
        #expect(c.counts(now: D(1_791_061_140)) == counts(1, 0))
        #expect(c.counts(now: D(1_791_061_200)) == .zero)                    // su 0.00
        c.apply(counts(0, 1), now: D(1_791_061_200))
        #expect(c.counts(now: D(1_791_061_200)) == counts(0, 1))             // the new day starts from 0
        #expect(c.day == 20730)
        #expect(c.counts(now: D(1_791_061_140)) == .zero)                    // Saturday's counts are gone
    }

    @Test func notUTCMidnight() {
        var c = DailyCounter()
        c.apply(counts(1, 0), now: D(1_790_983_800))                        // la 2.30 (UTC: Friday 23.30)
        #expect(c.counts(now: D(1_790_987_400)) == counts(1, 0))             // la 3.30 (UTC: Saturday 0.30)
        #expect(c.counts(now: N) == counts(1, 0))
    }

    @Test func dstDay25h() {
        var c = DailyCounter()
        c.apply(counts(1, 0), now: D(1_792_875_600))                        // su 25.10. 0.00 (+03)
        #expect(c.counts(now: D(1_792_908_000)) == counts(1, 0))             // su 8.00 (+02)
        #expect(c.counts(now: D(1_792_965_540)) == counts(1, 0))             // su 23.59, 24 h 59 min later
        #expect(c.counts(now: D(1_792_965_600)) == .zero)                    // ma 26.10. 0.00
    }

    @Test func dstDay23h() {
        var c = DailyCounter()
        c.apply(counts(0, 2), now: D(1_774_735_200))                        // su 29.3. 0.00 (+02)
        #expect(c.counts(now: D(1_774_746_000)) == counts(0, 2))             // su 4.00 (+03), right after the gap
        #expect(c.counts(now: D(1_774_817_940)) == counts(0, 2))             // su 23.59
        #expect(c.counts(now: D(1_774_818_000)) == .zero)                    // ma 30.3. 0.00
        #expect(c.day == 20541)
    }

    @Test func clampsAtZero() {
        var c = DailyCounter()
        c.apply(counts(-1, 0), now: N)
        #expect(c.counts(now: N) == .zero)
        #expect(c.archived == 0)
        c.apply(counts(1, 0), now: N)
        c.apply(counts(-2, -1), now: N)
        #expect(c.counts(now: N) == .zero)
        c.apply(counts(1, 1), now: N)
        #expect(c.counts(now: N) == counts(1, 1))
    }

    @Test func undoAfterMidnight() {
        var c = DailyCounter()
        c.apply(counts(1, 0), now: N)                                        // Saturday
        c.apply(counts(-1, 0), now: D(1_791_090_000))                       // undone on Sunday 8.00
        #expect(c.counts(now: D(1_791_090_000)) == counts(0, 0))
        #expect(c.day == 20730)
    }

    @Test func otherZone() {
        var c = DailyCounter()
        let utc = TimeZone(identifier: "UTC")!
        c.apply(counts(1, 0), now: D(1_790_983_800), timeZone: utc)          // Friday in UTC
        #expect(c.counts(now: D(1_790_987_400), timeZone: utc) == .zero)     // Saturday in UTC
    }

    @Test func lenientDecode() throws {
        let json = #"{"archived":"x","snoozed":2,"day":20729}"#
        let c = try JSONDecoder().decode(DailyCounter.self, from: Data(json.utf8))
        #expect(c.archived == 0)
        #expect(c.snoozed == 2)
        #expect(c.day == 20729)
        #expect(c.counts(now: N) == counts(0, 2))
        let empty = try JSONDecoder().decode(DailyCounter.self, from: Data("{}".utf8))
        #expect(empty == DailyCounter())
    }

    @Test func codableRoundTrip() throws {
        var c = DailyCounter()
        c.apply(counts(3, 2), now: N)
        let back = try JSONDecoder().decode(DailyCounter.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}

@MainActor
@Suite struct DailyCounterStoreTests {
    let N = D(1_791_018_000)
    let url = makeTempDir().appendingPathComponent("seise-today.json")

    func makeStore(clock: TestClock? = nil) -> DailyCounterStore {
        let clock = clock ?? TestClock(N)
        return DailyCounterStore(file: SettingsFile(fileURL: url), now: clock.closure)
    }

    @Test func defaultURL() {
        #expect(DailyCounterStore.defaultURL.lastPathComponent == "seise-today.json")
        #expect(DailyCounterStore.defaultURL.deletingLastPathComponent().standardizedFileURL
                == AppPaths.supportDirectory.standardizedFileURL)
    }

    @Test func storeRoundTrip() {
        let store = makeStore()
        store.record(ActivityCounts(archived: 1))
        #expect(store.counts(now: N) == ActivityCounts(archived: 1))
        let reopened = makeStore()
        #expect(reopened.counts(now: N) == ActivityCounts(archived: 1, snoozed: 0))
        #expect(reopened.counter == store.counter)
    }

    @Test func storeNoWriteForZero() {
        let store = makeStore()
        store.record(.zero)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.counts(now: N) == .zero)
    }

    @Test func storeAccumulatesAndUndoes() {
        let store = makeStore()
        store.record(ActivityCounts(archived: 1))
        store.record(ActivityCounts(snoozed: 3))
        store.record(ActivityCounts(snoozed: 3).negated)
        store.record(ActivityCounts(archived: 2))
        #expect(store.counts(now: N) == ActivityCounts(archived: 3, snoozed: 0))
        #expect(makeStore().counts(now: N) == ActivityCounts(archived: 3, snoozed: 0))
    }

    @Test func storeUsesItsClockForTheDay() {
        let clock = TestClock(D(1_791_061_140))                              // la 23.59
        let store = makeStore(clock: clock)
        store.record(ActivityCounts(archived: 2))
        #expect(store.counts(now: D(1_791_061_140)) == ActivityCounts(archived: 2))
        #expect(store.counts(now: D(1_791_061_200)) == .zero)                // su 0.00
        clock.set(D(1_791_090_000))                                          // su 8.00
        store.record(ActivityCounts(snoozed: 1))
        #expect(store.counts(now: D(1_791_090_000)) == ActivityCounts(snoozed: 1))
        #expect(makeStore(clock: clock).counts(now: D(1_791_090_000)) == ActivityCounts(snoozed: 1))
    }

    @Test func brokenFileStartsAtZero() throws {
        try Data("{ not json".utf8).write(to: url)
        let store = makeStore()
        #expect(store.counts(now: N) == .zero)
        store.record(ActivityCounts(archived: 1))
        #expect(makeStore().counts(now: N) == ActivityCounts(archived: 1))
    }
}
