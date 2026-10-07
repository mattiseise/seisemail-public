import Foundation

public enum SnoozeMenuKey: Sendable, Equatable { case digit(Int), up, down, left, right, enter, escape, tab, backspace, other }
public enum SnoozeMenuAction: Sendable, Equatable { case consumed, passThrough, close, snooze(Date) }
public enum CustomWakeCheck: Sendable, Equatable { case ok(Date), notInFuture, outOfRange }

public struct SnoozeMenuEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case preset(SnoozePreset), custom }
    public var kind: Kind
    /// SnoozePreset.title, or "Oma aika…"
    public var title: String
    /// nil for .custom, and for "Tänään illalla" once the evening has come
    public var wakeAt: Date?
    /// FinnishTime.full(wakeAt), "Ei enää tänään", or "Valitse päivä ja kellonaika"
    public var detail: String
    /// 1-based digit; fixed per row, so the keys stay the same in the evening
    public var number: Int
    public var id: Int { number }
    /// A preset without a time (tonight, after the evening hour) is shown dimmed and cannot be chosen.
    public var isEnabled: Bool { kind == .custom || wakeAt != nil }

    public init(kind: Kind, title: String, wakeAt: Date?, detail: String, number: Int) {
        self.kind = kind
        self.title = title
        self.wakeAt = wakeAt
        self.detail = detail
        self.number = number
    }
}

/// One day in the "Oma aika" calendar.
public struct CalendarCell: Sendable, Equatable, Identifiable {
    /// Civil day (days since 1970-01-01).
    public let day: Int
    public let dayOfMonth: Int
    /// false for the leading and trailing days of the neighbouring months.
    public let inMonth: Bool
    public let isToday: Bool
    public let isSelected: Bool
    /// Before today: shown dimmed, cannot be chosen.
    public let isPast: Bool
    public var id: Int { day }

    /// "pe 16.10." (the cell's accessibility label)
    public var label: String {
        let (_, month, dayOfMonth) = CivilTime.civil(days: day)
        return "\(FinnishTime.weekdays[CivilTime.isoWeekday(days: day) - 1]) \(dayOfMonth).\(month)."
    }
}

/// One row of the calendar: an ISO week, Monday first.
public struct CalendarWeek: Sendable, Equatable, Identifiable {
    /// ISO 8601 week number (Finnish "viikko").
    public let number: Int
    public let cells: [CalendarCell]
    public var id: Int { cells[0].day }
}

/// The `h` menu (conventions §1 "Ajat ja pikavalinnat"). Times are resolved once, at open.
public struct SnoozeMenuModel: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case list, custom }
    /// The picker with the keyboard in .custom.
    public enum CustomField: Sendable, Equatable { case day, time }
    public let targetCount: Int
    public let timeZone: TimeZone
    public private(set) var entries: [SnoozeMenuEntry]
    public private(set) var highlighted = 0
    public private(set) var mode = Mode.list
    /// The calendar first; tab switches (the view also sets it on a click, so tab goes to the other one).
    public var customField = CustomField.day
    /// "Oma aika": the civil day and the minutes after local midnight (0…1439); starts at the .tomorrow preset.
    public private(set) var customDay: Int
    public private(set) var customMinutes: Int
    /// The civil day the menu opened; earlier days cannot be chosen in the calendar.
    public let today: Int
    /// The 1st of the month the calendar shows.
    public private(set) var shownMonth: Int
    /// Digits typed for the time ("", "1", "14", "143", "1430"); cleared by any other change.
    public private(set) var timeEntry = ""

    /// The time chips under the time: 8.00, 12.00, 16.00, 20.00.
    public static let timeChoices = [8 * 60, 12 * 60, 16 * 60, 20 * 60]
    static let timeStep = 15

    public init(now: Date, targetCount: Int, settings: SnoozePresetSettings = .standard,
                timeZone: TimeZone = SnoozePresets.helsinki) {
        self.targetCount = targetCount
        self.timeZone = timeZone
        var list: [SnoozeMenuEntry] = []
        for preset in SnoozePreset.allCases {
            let wake = SnoozePresets.date(for: preset, now: now, timeZone: timeZone, settings: settings)
            let detail = wake.map { FinnishTime.full($0, now: now, timeZone: timeZone) } ?? "Ei enää tänään"
            list.append(.init(kind: .preset(preset), title: preset.title, wakeAt: wake, detail: detail,
                              number: list.count + 1))
        }
        list.append(.init(kind: .custom, title: "Oma aika…", wakeAt: nil, detail: "Valitse päivä ja kellonaika",
                          number: list.count + 1))
        entries = list
        highlighted = list.firstIndex(where: \.isEnabled) ?? 0
        today = CivilTime.localDay(of: now, in: timeZone)
        // Tomorrow always has a time.
        let tomorrow = FinnishTime.parts(SnoozePresets.date(for: .tomorrow, now: now, timeZone: timeZone, settings: settings)!, timeZone)
        customDay = tomorrow.day
        customMinutes = tomorrow.hour * 60 + tomorrow.minute
        shownMonth = Self.firstOfMonth(tomorrow.day)
    }

    /// The custom wake time. Setting it takes the local day and the whole minute (the calendar shows that month).
    public var customDate: Date {
        get {
            let (year, month, day) = CivilTime.civil(days: customDay)
            // Valid components never give nil.
            return CivilTime.instant(year: year, month: month, day: day, hour: customMinutes / 60,
                                     minute: customMinutes % 60, in: timeZone)!
        }
        set {
            let p = FinnishTime.parts(newValue, timeZone)
            customDay = p.day
            customMinutes = p.hour * 60 + p.minute
            shownMonth = Self.firstOfMonth(p.day)
            timeEntry = ""
        }
    }

    /// "Torkuta" / "Torkuta · 3 valittua" (also the card's accessibility label)
    public var title: String {
        targetCount > 1 ? "Torkuta · " + SnoozeText.counted(targetCount, "valittu", "valittua") : "Torkuta"
    }

    /// list: "Valitse numerolla tai ↑↓ ja ↩ · Esc sulkee"; custom: the keys of the part that has the keyboard. A
    /// no-break space keeps each key with its verb when the line wraps.
    public var footer: String {
        switch (mode, customField) {
        case (.list, _): "Valitse numerolla 1–\(entries.count) tai ↑↓ ja ↩ · Esc\u{A0}sulkee"
        case (.custom, .day): "Nuolet vaihtavat päivää · numerot asettavat kellonajan · ↩\u{A0}torkuttaa · Esc\u{A0}palaa listaan"
        case (.custom, .time): "Kirjoita aika (esim. 1430) tai ↑↓\u{A0}15\u{A0}min · Tab\u{A0}kalenteriin · ↩\u{A0}torkuttaa · Esc\u{A0}palaa listaan"
        }
    }

    // MARK: - Calendar and time ("Oma aika")

    /// "Lokakuu 2026"
    public var monthTitle: String {
        let (year, month, _) = CivilTime.civil(days: shownMonth)
        return "\(Self.months[month - 1]) \(year)"
    }

    /// Six weeks, so the card keeps its height from month to month.
    public var calendarWeeks: [CalendarWeek] {
        let (_, month, _) = CivilTime.civil(days: shownMonth)
        let start = InboxZeroWeeks.monday(of: shownMonth)
        return (0..<6).map { row in
            let monday = start + row * 7
            let cells = (0..<7).map { column -> CalendarCell in
                let day = monday + column
                let (_, m, d) = CivilTime.civil(days: day)
                return CalendarCell(day: day, dayOfMonth: d, inMonth: m == month, isToday: day == today,
                                    isSelected: day == customDay, isPast: day < today)
            }
            return CalendarWeek(number: Self.isoWeek(monday: monday), cells: cells)
        }
    }

    /// Not before today's month.
    public var canShowPreviousMonth: Bool { shownMonth > Self.firstOfMonth(today) }

    /// "8.00", "14.30"
    public var timeText: String { String(format: "%d.%02d", customMinutes / 60, customMinutes % 60) }

    /// ‹ and › over the calendar: the shown month only; the chosen day stays.
    public mutating func showMonth(by offset: Int) {
        var (year, month, _) = CivilTime.civil(days: shownMonth)
        month += offset
        while month > 12 { month -= 12; year += 1 }
        while month < 1 { month += 12; year -= 1 }
        shownMonth = max(CivilTime.days(year: year, month: month, day: 1), Self.firstOfMonth(today))
    }

    /// A click on a day: past days are ignored. The calendar gets the keyboard.
    public mutating func selectDay(_ day: Int) {
        guard day >= today else { return }
        customDay = day
        shownMonth = Self.firstOfMonth(day)
        customField = .day
        timeEntry = ""
    }

    /// A time chip.
    public mutating func setTime(minutes: Int) {
        customMinutes = min(max(minutes, 0), 24 * 60 - 1)
        timeEntry = ""
    }

    private mutating func moveDay(by days: Int) {
        selectDay(max(customDay + days, today))
    }

    /// ↑ to the next quarter hour, ↓ to the previous one, within the day.
    private mutating func stepTime(up: Bool) {
        let step = Self.timeStep
        let next = up ? (customMinutes / step + 1) * step : ((customMinutes + step - 1) / step - 1) * step
        customMinutes = min(max(next, 0), 24 * 60 - step)
        timeEntry = ""
    }

    /// A digit typed anywhere in "Oma aika" goes to the time: "8" → 8.00, "14" → 14.00, "83" → 8.30,
    /// "830" → 8.30, "1430" → 14.30. A digit that makes no valid time starts a new entry.
    private mutating func type(_ digit: Int) {
        customField = .time
        let candidate = (timeEntry.count >= 4 ? "" : timeEntry) + String(digit)
        if let minutes = Self.parseTime(candidate) {
            timeEntry = candidate
            customMinutes = minutes
        } else if let minutes = Self.parseTime(String(digit)) {
            timeEntry = String(digit)
            customMinutes = minutes
        }
    }

    private mutating func eraseDigit() {
        guard !timeEntry.isEmpty else { return }
        timeEntry.removeLast()
        if let minutes = Self.parseTime(timeEntry) { customMinutes = minutes }
    }

    /// Typed digits → minutes after midnight, nil when not a time.
    static func parseTime(_ digits: String) -> Int? {
        let d = digits.compactMap(\.wholeNumberValue)
        guard d.count == digits.count else { return nil }
        func at(_ hour: Int, _ minute: Int) -> Int? { (0...23).contains(hour) && (0...59).contains(minute) ? hour * 60 + minute : nil }
        switch d.count {
        case 1: return at(d[0], 0)
        case 2: return at(d[0] * 10 + d[1], 0) ?? at(d[0], d[1] * 10)
        case 3: return at(d[0], d[1] * 10 + d[2])
        case 4: return at(d[0] * 10 + d[1], d[2] * 10 + d[3])
        default: return nil
        }
    }

    static func firstOfMonth(_ day: Int) -> Int {
        let (year, month, _) = CivilTime.civil(days: day)
        return CivilTime.days(year: year, month: month, day: 1)
    }

    /// ISO 8601: the week belongs to the year of its Thursday.
    static func isoWeek(monday: Int) -> Int {
        let thursday = monday + 3
        let (year, _, _) = CivilTime.civil(days: thursday)
        return (thursday - CivilTime.days(year: year, month: 1, day: 1)) / 7 + 1
    }

    static let months = ["Tammikuu", "Helmikuu", "Maaliskuu", "Huhtikuu", "Toukokuu", "Kesäkuu",
                         "Heinäkuu", "Elokuu", "Syyskuu", "Lokakuu", "Marraskuu", "Joulukuu"]

    /// The same rule as SnoozeService.validatedWakeDate (SnoozeService.swift:45-50).
    public func customCheck(now: Date) -> CustomWakeCheck {
        let wake = SnoozeTime.ceilToMinute(customDate)
        if wake > SnoozeTime.latest { return .outOfRange }
        return wake > now ? .ok(wake) : .notInFuture
    }

    /// .ok → "Herää ti 6.10. klo 8.00"; .notInFuture → "Torkutusaika on jo mennyt"; .outOfRange → "Torkutusaika ei kelpaa"
    public func customPreview(now: Date) -> String {
        switch customCheck(now: now) {
        case .ok(let wake): "Herää " + FinnishTime.full(wake, now: now, timeZone: timeZone)
        case .notInFuture: "Torkutusaika on jo mennyt"
        case .outOfRange: "Torkutusaika ei kelpaa"
        }
    }

    public mutating func handle(_ key: SnoozeMenuKey, now: Date) -> SnoozeMenuAction {
        switch mode {
        case .list:
            switch key {
            case .digit(let n): return (1...entries.count).contains(n) ? choose(n - 1) : .consumed
            case .up: move(by: -1); return .consumed
            case .down: move(by: 1); return .consumed
            case .enter: return choose(highlighted)
            case .escape: return .close
            case .left, .right, .tab, .backspace, .other: return .consumed   // swallowed: e, #, tab… never reach the list
            }
        case .custom:
            switch key {
            case .enter:
                if case .ok(let wake) = customCheck(now: now) { return .snooze(wake) }
                return .consumed
            case .escape:
                mode = .list
                timeEntry = ""
            case .tab:
                customField = customField == .day ? .time : .day
                timeEntry = ""
            case .digit(let n): type(n)
            case .backspace: eraseDigit()
            case .left: if customField == .day { moveDay(by: -1) }
            case .right: if customField == .day { moveDay(by: 1) }
            case .up: if customField == .day { moveDay(by: -7) } else { stepTime(up: true) }
            case .down: if customField == .day { moveDay(by: 7) } else { stepTime(up: false) }
            case .other: break
            }
            return .consumed
        }
    }

    /// To the next enabled row in that direction; stays put at either end.
    private mutating func move(by step: Int) {
        var index = highlighted + step
        while entries.indices.contains(index) {
            if entries[index].isEnabled { highlighted = index; return }
            index += step
        }
    }

    /// Mouse, and digits: a preset → .snooze(wakeAt); custom → mode = .custom, .consumed; a dimmed row → .consumed.
    /// The chosen entry becomes the highlighted one, so Esc from the date picker returns to "Oma aika…".
    public mutating func choose(_ index: Int) -> SnoozeMenuAction {
        guard entries.indices.contains(index), entries[index].isEnabled else { return .consumed }
        highlighted = index
        let entry = entries[index]
        switch entry.kind {
        case .preset:
            guard let wake = entry.wakeAt else { return .consumed }
            return .snooze(wake)
        case .custom:
            mode = .custom
            customField = .day
            return .consumed
        }
    }
}
