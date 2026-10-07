import Foundation
import Testing
@testable import MailCore

@Suite struct SnoozePresetsTests {
    struct Case: Decodable {
        var name: String
        var now: Double
        var preset: String
        /// null: the preset is not offered (tonight after the evening hour)
        var expected: Double?
        var expectedStamp: String?
        var timeZone: String?
        var eveningHour: Int?
        var morningHour: Int?
        var morningMinute: Int?
    }

    let hel = TimeZone(identifier: "Europe/Helsinki")!

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }

    // MARK: - Shared table (snooze_preset_cases.json, also read by the Windows port)

    @Test func presetTable() throws {
        let table = try JSONDecoder().decode([Case].self, from: Fixture.data("snooze_preset_cases"))
        #expect(table.count == 44)
        #expect(Set(table.map(\.preset)) == Set(SnoozePreset.allCases.map(\.rawValue)))
        for row in table {
            let comment = Comment(rawValue: row.name)
            let preset = try #require(SnoozePreset(rawValue: row.preset), comment)
            let zone = try #require(TimeZone(identifier: row.timeZone ?? "Europe/Helsinki"), comment)
            var settings = SnoozePresetSettings()
            if let hour = row.eveningHour { settings.eveningHour = hour }
            if let hour = row.morningHour { settings.morningHour = hour }
            if let minute = row.morningMinute { settings.morningMinute = minute }
            let date = SnoozePresets.date(for: preset, now: D(row.now), timeZone: zone, settings: settings)
            #expect(date == row.expected.map(D), comment)
            #expect(date.map(SnoozeTime.encode) == row.expectedStamp, comment)
        }
    }

    @Test func defaultsAreMattisValues() {
        let s = SnoozePresetSettings.standard
        #expect(s.eveningHour == 20)
        #expect(s.morningHour == 8)
        #expect(s.morningMinute == 0)
        #expect(SnoozePresets.helsinki.identifier == "Europe/Helsinki")
        // Default arguments are Helsinki and .standard.
        #expect(SnoozePresets.date(for: .tomorrow, now: D(1_791_018_000)) == D(1_791_090_000))
        #expect(SnoozePresets.date(for: .tonight, now: D(1_791_018_000)) == D(1_791_046_800))   // la 20.00
    }

    @Test func outOfRangeSettingsClamped() {
        let now = D(1_791_018_000)                  // Sat 3.10.2026 12:00 EEST
        func tomorrow(hour: Int = 8, minute: Int = 0) -> Date {
            SnoozePresets.date(for: .tomorrow, now: now, settings: SnoozePresetSettings(morningHour: hour, morningMinute: minute))!
        }
        #expect(tomorrow(hour: 24) == tomorrow(hour: 23))
        #expect(SnoozeTime.encode(tomorrow(hour: 24)) == "20261004T2000Z")        // Sun 23:00 EEST
        #expect(tomorrow(hour: -1) == tomorrow(hour: 0))
        #expect(SnoozeTime.encode(tomorrow(hour: -1)) == "20261003T2100Z")        // Sun 00:00 EEST
        #expect(SnoozeTime.encode(tomorrow(minute: 75)) == "20261004T0559Z")      // Sun 08:59 EEST
        #expect(SnoozeTime.encode(tomorrow(minute: -5)) == "20261004T0500Z")
        func tonight(_ hour: Int) -> Date? {
            SnoozePresets.date(for: .tonight, now: now, settings: SnoozePresetSettings(eveningHour: hour))
        }
        #expect(tonight(24).map(SnoozeTime.encode) == "20261003T2000Z")         // Sat 23:00 EEST
        #expect(tonight(-1) == nil)                                              // 0.00 has passed at noon
        #expect(tonight(12) == nil)                                              // exactly now is not later
    }

    // MARK: - CivilTime.instant (Temporal "compatible")

    @Test func instantSpringGapShiftsForward() {
        // Local 03:30 does not exist on 29.3.2026; shifted by the gap: 04:30 EEST = 01:30Z.
        #expect(CivilTime.instant(year: 2026, month: 3, day: 29, hour: 3, minute: 30, in: hel) == D(1_774_747_800))
        #expect(CivilTime.instant(year: 2026, month: 3, day: 29, hour: 3, minute: 0, in: hel) == D(1_774_746_000))
        #expect(CivilTime.instant(year: 2026, month: 3, day: 29, hour: 3, minute: 59, in: hel) == D(1_774_749_540))
    }

    @Test func instantAutumnOverlapPicksEarlier() {
        // Local 03:00–03:59 occurs twice on 25.10.2026; the EEST one is earlier.
        #expect(CivilTime.instant(year: 2026, month: 10, day: 25, hour: 3, minute: 30, in: hel) == D(1_792_888_200))
        #expect(CivilTime.instant(year: 2026, month: 10, day: 25, hour: 3, minute: 0, in: hel) == D(1_792_886_400))
        #expect(CivilTime.instant(year: 2026, month: 10, day: 25, hour: 3, minute: 59, in: hel) == D(1_792_889_940))
    }

    @Test func instantBoundaries() {
        #expect(CivilTime.instant(year: 2026, month: 3, day: 29, hour: 4, minute: 0, in: hel) == D(1_774_746_000))
        #expect(CivilTime.instant(year: 2026, month: 3, day: 29, hour: 2, minute: 59, in: hel) == D(1_774_745_940))
        #expect(CivilTime.instant(year: 2026, month: 10, day: 25, hour: 4, minute: 0, in: hel) == D(1_792_893_600))
        #expect(CivilTime.instant(year: 2026, month: 10, day: 25, hour: 2, minute: 59, in: hel) == D(1_792_886_340))
        #expect(CivilTime.instant(year: 2026, month: 10, day: 5, hour: 8, minute: 0, in: hel) == D(1_791_176_400))
        #expect(CivilTime.instant(year: 2026, month: 10, day: 5, hour: 8, minute: 0, in: TimeZone(identifier: "UTC")!) == D(1_791_187_200))
    }

    @Test func instantRejectsInvalid() {
        #expect(CivilTime.instant(year: 2026, month: 2, day: 30, hour: 8, minute: 0, in: hel) == nil)
        #expect(CivilTime.instant(year: 2027, month: 2, day: 29, hour: 8, minute: 0, in: hel) == nil)
        #expect(CivilTime.instant(year: 2026, month: 13, day: 1, hour: 8, minute: 0, in: hel) == nil)
        #expect(CivilTime.instant(year: 2026, month: 0, day: 1, hour: 8, minute: 0, in: hel) == nil)
        #expect(CivilTime.instant(year: 2026, month: 10, day: 0, hour: 8, minute: 0, in: hel) == nil)
        #expect(CivilTime.instant(year: 2026, month: 10, day: 5, hour: 24, minute: 0, in: hel) == nil)
        #expect(CivilTime.instant(year: 2026, month: 10, day: 5, hour: 8, minute: 60, in: hel) == nil)
        #expect(CivilTime.instant(year: 2026, month: 10, day: 5, hour: -1, minute: 0, in: hel) == nil)
    }

    // MARK: - Invariants, checked against Foundation's Calendar as an independent oracle

    @Test func presetsAreFutureWholeMinutes() {
        // 26.3.–2.4.2026 and 22.–29.10.2026 (UTC), every 7 min 13 s, so seconds and DST days are both covered.
        let windows: [(from: Double, to: Double)] = [(1_774_483_200, 1_775_088_000), (1_792_627_200, 1_793_232_000)]
        let calendar = self.calendar
        var failures: [String] = []
        var checked = 0
        for window in windows {
            var t = window.from
            while t < window.to {
                let now = D(t)
                let today = calendar.startOfDay(for: now)
                func check(_ label: String, _ date: Date?, hour: Int = 8, days: ClosedRange<Int>, weekday: Int? = nil,
                           firstOfMonth: Bool = false) {
                    guard let date else { return failures.append("\(label) now=\(t) got=nil") }
                    let c = calendar.dateComponents([.hour, .minute, .second, .weekday, .day], from: date)
                    let dayDiff = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? -1
                    let ok = date > now && date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0
                        && c.hour == hour && c.minute == 0 && c.second == 0 && days.contains(dayDiff)
                        && (weekday == nil || c.weekday == weekday) && (!firstOfMonth || c.day == 1)
                    if !ok { failures.append("\(label) now=\(t) got=\(date.timeIntervalSince1970)") }
                }
                let tonight = SnoozePresets.date(for: .tonight, now: now)
                if calendar.component(.hour, from: now) < 20 {
                    check("tonight", tonight, hour: 20, days: 0...0)
                } else if tonight != nil {
                    failures.append("tonight now=\(t) got=\(tonight!.timeIntervalSince1970), expected nil")
                }
                check("tomorrow", SnoozePresets.date(for: .tomorrow, now: now), days: 1...1)
                check("nextWeek", SnoozePresets.date(for: .nextWeek, now: now), days: 1...7, weekday: 2)
                check("nextMonth", SnoozePresets.date(for: .nextMonth, now: now), days: 1...31, firstOfMonth: true)
                checked += 1
                t += 7 * 60 + 13
            }
        }
        #expect(checked > 2_700)
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(5).joined(separator: "\n")))
    }

    @Test func titlesAreFinnish() {
        #expect(SnoozePreset.allCases == [.tonight, .tomorrow, .nextWeek, .nextMonth])
        #expect(SnoozePreset.allCases.map(\.title) == ["Tänään illalla", "Huomenna", "Ensi viikolla", "Ensi kuussa"])
    }
}
