import Foundation
import Testing
@testable import MailCore

@Suite struct SnoozeTimeTests {
    struct Cases: Decodable {
        struct Encode: Decodable { var name: String; var epoch: Double; var stamp: String }
        struct Decode: Decodable { var name: String; var stamp: String; var epoch: Double }
        struct Invalid: Decodable { var name: String; var stamp: String }
        var encode: [Encode]
        var decode: [Decode]
        var invalid: [Invalid]
    }

    let scheme = SnoozeLabelScheme.standard

    func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Fixture.data("snooze_time_cases"))
    }

    // MARK: - Shared table (snooze_time_cases.json, also read by the Windows port)

    @Test func encodeTable() throws {
        let table = try cases().encode
        #expect(table.count == 9)
        for row in table {
            #expect(SnoozeTime.encode(D(row.epoch)) == row.stamp, Comment(rawValue: row.name))
        }
    }

    @Test func decodeTable() throws {
        let table = try cases().decode
        #expect(table.count == 6)
        for row in table {
            #expect(SnoozeTime.decode(row.stamp) == D(row.epoch), Comment(rawValue: row.name))
        }
    }

    @Test func invalidTable() throws {
        let table = try cases().invalid
        #expect(table.count == 19)
        for row in table {
            #expect(SnoozeTime.decode(row.stamp) == nil, Comment(rawValue: row.name))
        }
    }

    // MARK: - Swift-only

    @Test func roundTripEveryMinuteOnDSTDays() {
        // 2026-03-29 and 2026-10-25 00:00Z (the Helsinki DST switches are at 01:00Z on both days).
        for dayStart in [1_774_742_400.0, 1_792_886_400.0] {
            for minute in 0..<1440 {
                for offset in [0.0, 17.0] {
                    let d = D(dayStart + Double(minute * 60) + offset)
                    let encoded = SnoozeTime.encode(d)
                    #expect(SnoozeTime.decode(encoded) == SnoozeTime.ceilToMinute(d), Comment(rawValue: encoded))
                }
            }
        }
    }

    @Test func ceilToMinuteKeepsExactMinutes() {
        #expect(SnoozeTime.ceilToMinute(D(1_791_180_000)) == D(1_791_180_000))
        #expect(SnoozeTime.ceilToMinute(D(1_791_180_000.001)) == D(1_791_180_060))
        #expect(SnoozeTime.ceilToMinute(D(1_791_179_940.999)) == D(1_791_180_000))
        #expect(SnoozeTime.ceilToMinute(D(0)) == D(0))
    }

    @Test func latestIsLastMinuteOf9999() {
        #expect(SnoozeTime.latest == D(253_402_300_740))
        #expect(SnoozeTime.encode(SnoozeTime.latest) == "99991231T2359Z")
    }

    @Test func standardSchemeNamesAndVisibility() {
        #expect(SeiseLabels.snoozeMarker == "Torkku")
        #expect(SeiseLabels.snoozeTimePrefix == "Torkku/")
        #expect(scheme.marker == "Torkku")
        #expect(scheme.timePrefix == "Torkku/")
        #expect(scheme.markerVisibility == LabelVisibility(labelList: .labelShow, messageList: .show))
        #expect(scheme.timeVisibility == LabelVisibility(labelList: .labelHide, messageList: .hide))
        #expect(scheme.timeLabelName(for: D(1_791_176_400)) == "Torkku/20261005T0500Z")
        #expect(scheme.timeLabelName(for: D(1_791_176_401)) == "Torkku/20261005T0501Z")
    }

    @Test func schemeParsesOnlyExactNames() {
        #expect(scheme.wakeDate(fromLabelName: "Torkku/20261005T0600Z") == D(1_791_180_000))
        for name in ["Torkku/20261005T0600Z/x", "torkku/20261005T0600Z", "TORKKU/20261005T0600Z", "Torkku",
                     "Torkku20261005T0600Z", "Torkku/", "Torkku/garbage", "Torkku/20261005T0600Z ", "x/Torkku/20261005T0600Z"] {
            #expect(scheme.wakeDate(fromLabelName: name) == nil, Comment(rawValue: name))
        }
    }

    @Test func isTimeLabelVsValid() {
        #expect(scheme.isTimeLabel("Torkku/garbage"))
        #expect(scheme.isTimeLabel("Torkku/20261005T0600Z"))
        #expect(scheme.isTimeLabel("Torkku20261005T0600Z") == false)
        #expect(scheme.isTimeLabel("Torkku") == false)
        #expect(scheme.isTimeLabel("torkku/20261005T0600Z") == false)
    }

    @Test func renamedScheme() {
        let custom = SnoozeLabelScheme(marker: "Snoozed", timePrefix: "Snooze/")
        #expect(custom.markerVisibility == .shown)
        #expect(custom.timeVisibility == .hidden)
        let name = custom.timeLabelName(for: D(1_791_180_000))
        #expect(name == "Snooze/20261005T0600Z")
        #expect(custom.wakeDate(fromLabelName: name) == D(1_791_180_000))
        #expect(custom.wakeDate(fromLabelName: "Torkku/20261005T0600Z") == nil)
        #expect(custom.isTimeLabel("Torkku/20261005T0600Z") == false)
    }

    @Test func earliestWakeDateIgnoresInvalidAndUnknown() {
        let names = [
            "L1": "Torkku/20261005T0800Z",
            "L2": "Torkku/garbage",
            "L3": "Torkku/20261005T0600Z",
            "L4": "Torkku",
        ]
        #expect(scheme.earliestWakeDate(labelIDs: ["L1", "L2", "L3", "L4", "L9"], namesByID: names) == D(1_791_180_000))
        #expect(scheme.earliestWakeDate(labelIDs: ["L1", "L2"], namesByID: names) == D(1_791_187_200))
        #expect(scheme.earliestWakeDate(labelIDs: ["L2"], namesByID: names) == nil)
        #expect(scheme.earliestWakeDate(labelIDs: ["L4", "L9"], namesByID: names) == nil)
        #expect(scheme.earliestWakeDate(labelIDs: [], namesByID: names) == nil)
    }

    @Test func civilTimeRoundTrip() {
        #expect(CivilTime.days(year: 1970, month: 1, day: 1) == 0)
        #expect(CivilTime.isoWeekday(days: 0) == 4)                       // Thursday
        #expect(CivilTime.days(year: 2026, month: 10, day: 5) == 20_731)
        #expect(CivilTime.isoWeekday(days: 20_731) == 1)                  // Monday
        #expect(CivilTime.days(year: 2026, month: 3, day: 29) == 20_541)
        #expect(CivilTime.isoWeekday(days: 20_541) == 7)                  // Sunday, spring DST
        #expect(CivilTime.days(year: 2026, month: 10, day: 25) == 20_751)
        #expect(CivilTime.isoWeekday(days: 20_751) == 7)                  // Sunday, autumn DST
        #expect(CivilTime.isoWeekday(days: -1) == 3)                      // 1969-12-31, Wednesday
        let samples: [(Int, Int, Int, Int)] = [
            (2000, 2, 29, 11_016), (2026, 3, 29, 20_541), (2026, 10, 25, 20_751),
            (9999, 12, 31, 2_932_896), (1969, 12, 31, -1),
        ]
        for (y, m, d, days) in samples {
            #expect(CivilTime.days(year: y, month: m, day: d) == days)
            let back = CivilTime.civil(days: days)
            #expect(back.year == y && back.month == m && back.day == d, Comment(rawValue: "\(y)-\(m)-\(d)"))
        }
        #expect(CivilTime.floorDiv(-1, 86_400) == -1)
        #expect(CivilTime.floorDiv(86_399, 86_400) == 0)
        #expect(CivilTime.floorDiv(-86_400, 86_400) == -1)
        #expect(CivilTime.floorDiv(-86_401, 86_400) == -2)
        #expect(CivilTime.daysInMonth(year: 2028, month: 2) == 29)
        #expect(CivilTime.daysInMonth(year: 2027, month: 2) == 28)
        #expect(CivilTime.daysInMonth(year: 2000, month: 2) == 29)
        #expect(CivilTime.daysInMonth(year: 2100, month: 2) == 28)
        #expect(CivilTime.daysInMonth(year: 2026, month: 4) == 30)
        #expect(CivilTime.daysInMonth(year: 2026, month: 12) == 31)
    }

    @Test func helsinkiOffsetsAndLocalDayAroundDST() {
        let hel = TimeZone(identifier: "Europe/Helsinki")!
        // Spring: 2026-03-29 01:00Z (03:00 EET → 04:00 EEST).
        #expect(CivilTime.offset(hel, atEpochSeconds: 1_774_745_999) == 7200)
        #expect(CivilTime.offset(hel, atEpochSeconds: 1_774_746_000) == 10_800)
        // Autumn: 2026-10-25 01:00Z (04:00 EEST → 03:00 EET).
        #expect(CivilTime.offset(hel, atEpochSeconds: 1_792_889_999) == 10_800)
        #expect(CivilTime.offset(hel, atEpochSeconds: 1_792_890_000) == 7200)
        // Sat 3.10.2026 23:59:59 EEST is day 20729; one second later is Sunday, day 20730.
        #expect(CivilTime.localDay(of: D(1_791_061_199), in: hel) == 20_729)
        #expect(CivilTime.localDay(of: D(1_791_061_200), in: hel) == 20_730)
        #expect(CivilTime.localDay(of: D(1_791_061_199.5), in: hel) == 20_729)
    }
}
