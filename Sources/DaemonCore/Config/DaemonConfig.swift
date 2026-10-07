import Foundation

/// Per-feature mode (D10). `shadow` decides and logs but never writes to Gmail.
public enum FeatureMode: String, Codable, Sendable, CaseIterable {
    case off, shadow, live
}

/// `daemon.json` (design §5, §9.1). Missing keys take their defaults; unknown keys make the file invalid,
/// which keeps the last good copy in effect (§10).
public struct DaemonConfig: Codable, Sendable, Equatable {
    public struct Notify: Codable, Sendable, Equatable {
        /// Expiry notes into the inbox (`messages.insert`).
        public var inboxNote = true
        /// Notes at these many hours before the refresh token expires.
        public var warnHours = [24, 3]
        /// Opt-in argv hook (no shell), e.g. a Telegram script. nil = off. Never put a secret here: argv is
        /// visible in `ps` to every local user while the hook runs; the script reads its own secrets from its
        /// own 0600 file or the Keychain (design §9.1, §11.3). `daemon.json` itself is written 0600.
        public var command: [String]? = nil
        /// Daily needsLogin reminder hour, Helsinki time.
        public var reminderHour = 9

        public init(inboxNote: Bool = true, warnHours: [Int] = [24, 3], command: [String]? = nil, reminderHour: Int = 9) {
            self.inboxNote = inboxNote
            self.warnHours = warnHours
            self.command = command
            self.reminderHour = reminderHour
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case inboxNote, warnHours, command, reminderHour }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try StrictKeys.check(decoder, CodingKeys.allCases.map(\.rawValue))
            let d = Notify()
            inboxNote = try c.decodeIfPresent(Bool.self, forKey: .inboxNote) ?? d.inboxNote
            warnHours = try c.decodeIfPresent([Int].self, forKey: .warnHours) ?? d.warnHours
            command = try c.decodeIfPresent([String].self, forKey: .command)
            reminderHour = try c.decodeIfPresent(Int.self, forKey: .reminderHour) ?? d.reminderHour
        }
    }

    public struct Sync: Codable, Sendable, Equatable {
        /// The sorter's own cap (D8): wakes keep the rest of the daemon's 3,000/min share.
        public var unitsPerMinute = 2_000
        /// The largest accepted `unitsPerMinute` (D8: wakes keep ≥ 1,000 of the daemon's 3,000/min).
        public static let maxUnitsPerMinute = 2_000
        public var sweepMinutes = 30
        public var sweepWindowHours = 2
        public var resyncMaxDays = 30

        public init(unitsPerMinute: Int = 2_000, sweepMinutes: Int = 30, sweepWindowHours: Int = 2, resyncMaxDays: Int = 30) {
            self.unitsPerMinute = unitsPerMinute
            self.sweepMinutes = sweepMinutes
            self.sweepWindowHours = sweepWindowHours
            self.resyncMaxDays = resyncMaxDays
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case unitsPerMinute, sweepMinutes, sweepWindowHours, resyncMaxDays }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try StrictKeys.check(decoder, CodingKeys.allCases.map(\.rawValue))
            let d = Sync()
            unitsPerMinute = try c.decodeIfPresent(Int.self, forKey: .unitsPerMinute) ?? d.unitsPerMinute
            sweepMinutes = try c.decodeIfPresent(Int.self, forKey: .sweepMinutes) ?? d.sweepMinutes
            sweepWindowHours = try c.decodeIfPresent(Int.self, forKey: .sweepWindowHours) ?? d.sweepWindowHours
            resyncMaxDays = try c.decodeIfPresent(Int.self, forKey: .resyncMaxDays) ?? d.resyncMaxDays
        }
    }

    public struct SentBackfill: Codable, Sendable, Equatable {
        public var days = 730
        public var maxMessages = 5_000

        public init(days: Int = 730, maxMessages: Int = 5_000) {
            self.days = days
            self.maxMessages = maxMessages
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case days, maxMessages }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try StrictKeys.check(decoder, CodingKeys.allCases.map(\.rawValue))
            let d = SentBackfill()
            days = try c.decodeIfPresent(Int.self, forKey: .days) ?? d.days
            maxMessages = try c.decodeIfPresent(Int.self, forKey: .maxMessages) ?? d.maxMessages
        }
    }

    public var schema = 1
    public var wake: FeatureMode = .live
    public var sorting: FeatureMode = .shadow
    public var disabledAccounts: [String] = []
    public var notify = Notify()
    public var sync = Sync()
    public var sentBackfill = SentBackfill()

    public init(schema: Int = 1, wake: FeatureMode = .live, sorting: FeatureMode = .shadow, disabledAccounts: [String] = [],
                notify: Notify = Notify(), sync: Sync = Sync(), sentBackfill: SentBackfill = SentBackfill()) {
        self.schema = schema
        self.wake = wake
        self.sorting = sorting
        self.disabledAccounts = disabledAccounts
        self.notify = notify
        self.sync = sync
        self.sentBackfill = sentBackfill
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, wake, sorting, disabledAccounts, notify, sync, sentBackfill
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try StrictKeys.check(decoder, CodingKeys.allCases.map(\.rawValue))
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        wake = try c.decodeIfPresent(FeatureMode.self, forKey: .wake) ?? .live
        sorting = try c.decodeIfPresent(FeatureMode.self, forKey: .sorting) ?? .shadow
        disabledAccounts = try c.decodeIfPresent([String].self, forKey: .disabledAccounts) ?? []
        notify = try c.decodeIfPresent(Notify.self, forKey: .notify) ?? Notify()
        sync = try c.decodeIfPresent(Sync.self, forKey: .sync) ?? Sync()
        sentBackfill = try c.decodeIfPresent(SentBackfill.self, forKey: .sentBackfill) ?? SentBackfill()
    }

    /// Parses and validates `daemon.json`. Problems are Finnish, for `status`.
    public static func decode(_ data: Data) throws(ConfigError) -> DaemonConfig {
        let config: DaemonConfig
        do {
            config = try JSONDecoder().decode(DaemonConfig.self, from: data)
        } catch {
            throw ConfigError(problems: ["daemon.json: " + ConfigError.describe(error)])
        }
        var problems: [String] = []
        if config.schema != 1 { problems.append("daemon.json: tuntematon skeema \(config.schema) (tuettu 1)") }
        if config.notify.warnHours.contains(where: { $0 <= 0 || $0 > 24 * 7 }) {
            problems.append("daemon.json: notify.warnHours: arvon oltava 1…168")
        }
        if !(0...23).contains(config.notify.reminderHour) { problems.append("daemon.json: notify.reminderHour: 0…23") }
        if let command = config.notify.command, command.first.map({ !$0.hasPrefix("/") }) ?? true {
            problems.append("daemon.json: notify.command: ensimmäisen alkion oltava absoluuttinen polku")
        }
        // D8: at most 2,000 of the daemon's 3,000/min, so wakes always keep ≥ 1,000 (and the few unbudgeted
        // label and retry calls fit in that headroom).
        if config.sync.unitsPerMinute < 100 || config.sync.unitsPerMinute > Sync.maxUnitsPerMinute {
            problems.append("daemon.json: sync.unitsPerMinute: 100…\(Sync.maxUnitsPerMinute)")
        }
        if config.sync.sweepMinutes < 1 { problems.append("daemon.json: sync.sweepMinutes: vähintään 1") }
        if config.sync.sweepWindowHours < 1 { problems.append("daemon.json: sync.sweepWindowHours: vähintään 1") }
        if config.sync.resyncMaxDays < 1 { problems.append("daemon.json: sync.resyncMaxDays: vähintään 1") }
        if config.sentBackfill.days < 1 || config.sentBackfill.maxMessages < 0 {
            problems.append("daemon.json: sentBackfill: days ≥ 1, maxMessages ≥ 0")
        }
        guard problems.isEmpty else { throw ConfigError(problems: problems) }
        return config
    }

    /// Pretty JSON with sorted keys, as `init` and `mode` write it.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Whether `email` is listed in `disabledAccounts` (case-insensitively).
    public func isDisabled(_ email: String) -> Bool {
        disabledAccounts.contains { $0.lowercased() == email.lowercased() }
    }
}

public struct ConfigError: Error, Equatable, Sendable {
    public var problems: [String]

    public init(problems: [String]) {
        self.problems = problems
    }

    /// A short Finnish description of a decoding error, with the key path.
    static func describe(_ error: any Error) -> String {
        func path(_ codingPath: [any CodingKey]) -> String { StrictKeys.path(codingPath) }
        switch error {
        case let e as StrictKeys.UnknownKey:
            return "tuntematon avain \(e.path)"
        case let e as StrictKeys.UnknownType:
            return "tuntematon ehtotyyppi \(e.type) kohdassa \(e.path)"
        case DecodingError.dataCorrupted(let c):
            return c.codingPath.isEmpty ? "ei kelvollista JSONia" : "virheellinen arvo kohdassa \(path(c.codingPath))"
        case DecodingError.keyNotFound(let key, let c):
            return "puuttuva avain \((c.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "väärä tyyppi kohdassa \(path(c.codingPath))"
        default:
            return "ei luettavissa"
        }
    }
}

/// Rejects keys a decoder does not know (design §7.2 "unknown keys or types are errors").
enum StrictKeys {
    struct UnknownKey: Error {
        var path: String
    }

    struct UnknownType: Error {
        var path: String
        var type: String
    }

    /// `rules[0].any[1].type`
    static func path(_ codingPath: [any CodingKey]) -> String {
        var out = ""
        for key in codingPath {
            if let i = key.intValue { out += "[\(i)]" } else { out += (out.isEmpty ? "" : ".") + key.stringValue }
        }
        return out
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func check(_ decoder: any Decoder, _ known: [String]) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = container.allKeys.map(\.stringValue).sorted().first(where: { !known.contains($0) }) {
            let prefix = path(decoder.codingPath)
            throw UnknownKey(path: prefix.isEmpty ? unknown : prefix + "." + unknown)
        }
    }
}
