import Foundation

/// One account in `status.json` (design §9.4).
public struct AccountStatus: Codable, Sendable, Equatable {
    public struct Today: Codable, Sendable, Equatable {
        public var woken = 0
        public var cancelled = 0
        public var cleaned = 0
        public var classified = 0
        public var propagated = 0
        public var unmatched = 0

        public init(woken: Int = 0, cancelled: Int = 0, cleaned: Int = 0, classified: Int = 0, propagated: Int = 0, unmatched: Int = 0) {
            self.woken = woken
            self.cancelled = cancelled
            self.cleaned = cleaned
            self.classified = classified
            self.propagated = propagated
            self.unmatched = unmatched
        }
    }

    public var email: String
    /// `starting`, `backfillingSent`, `running`, `needsLogin`, `stateError`.
    public var phase: String
    /// For needsLogin: `expired`, `tokenMissing`, `tokenUnreadable`, `clientChanged`, `wrongAccount`.
    public var reason: String?
    public var expiresAt: Date?
    /// Short Finnish text when Matti should act or look; nil when all is well.
    public var attention: String?
    public var lastWakeAt: Date?
    public var lastWakeResult: String?
    public var nextWakeAt: Date?
    public var lastSyncAt: Date?
    public var lastSyncResult: String?
    public var watermarkAgeSeconds: Int?
    /// `pending`, `running`, `done`
    public var sentBackfill: String?
    /// "x/y" while the sent backfill runs.
    public var sentBackfillProgress: String?
    public var scan: String?
    public var skewSeconds: Double?
    public var unitsLastMinute: Int?
    public var today: Today
    /// The command to run, when one would help.
    public var action: String?
    /// When sorting first ran in shadow / live mode (state §9.2); nil until known. `backfill --since` after
    /// going live starts from the shadow start's day (§16).
    public var shadowSince: Date?
    public var liveSince: Date?

    public init(email: String, phase: String, reason: String? = nil, expiresAt: Date? = nil, attention: String? = nil,
                lastWakeAt: Date? = nil, lastWakeResult: String? = nil, nextWakeAt: Date? = nil, lastSyncAt: Date? = nil,
                lastSyncResult: String? = nil, watermarkAgeSeconds: Int? = nil, sentBackfill: String? = nil,
                sentBackfillProgress: String? = nil, scan: String? = nil, skewSeconds: Double? = nil,
                unitsLastMinute: Int? = nil, today: Today = Today(), action: String? = nil,
                shadowSince: Date? = nil, liveSince: Date? = nil) {
        self.email = email
        self.phase = phase
        self.reason = reason
        self.expiresAt = expiresAt
        self.attention = attention
        self.lastWakeAt = lastWakeAt
        self.lastWakeResult = lastWakeResult
        self.nextWakeAt = nextWakeAt
        self.lastSyncAt = lastSyncAt
        self.lastSyncResult = lastSyncResult
        self.watermarkAgeSeconds = watermarkAgeSeconds
        self.sentBackfill = sentBackfill
        self.sentBackfillProgress = sentBackfillProgress
        self.scan = scan
        self.skewSeconds = skewSeconds
        self.unitsLastMinute = unitsLastMinute
        self.today = today
        self.action = action
        self.shadowSince = shadowSince
        self.liveSince = liveSince
    }

    /// Every key is written, unknown values as `null` (design §9.4 shows `"attention": null`): readers such as
    /// local monitors see the same shape whatever the phase.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(email, forKey: .email)
        try c.encode(phase, forKey: .phase)
        try c.encode(reason, forKey: .reason)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(attention, forKey: .attention)
        try c.encode(lastWakeAt, forKey: .lastWakeAt)
        try c.encode(lastWakeResult, forKey: .lastWakeResult)
        try c.encode(nextWakeAt, forKey: .nextWakeAt)
        try c.encode(lastSyncAt, forKey: .lastSyncAt)
        try c.encode(lastSyncResult, forKey: .lastSyncResult)
        try c.encode(watermarkAgeSeconds, forKey: .watermarkAgeSeconds)
        try c.encode(sentBackfill, forKey: .sentBackfill)
        try c.encode(sentBackfillProgress, forKey: .sentBackfillProgress)
        try c.encode(scan, forKey: .scan)
        try c.encode(skewSeconds, forKey: .skewSeconds)
        try c.encode(unitsLastMinute, forKey: .unitsLastMinute)
        try c.encode(today, forKey: .today)
        try c.encode(action, forKey: .action)
        try c.encode(shadowSince, forKey: .shadowSince)
        try c.encode(liveSince, forKey: .liveSince)
    }
}

/// `daemon/status.json`: the contract for `mak8r-daemon status` and for local monitors (design §9.4).
public struct DaemonStatus: Codable, Sendable, Equatable {
    public struct Modes: Codable, Sendable, Equatable {
        public var wake: FeatureMode
        public var sorting: FeatureMode

        public init(wake: FeatureMode, sorting: FeatureMode) {
            self.wake = wake
            self.sorting = sorting
        }
    }

    public var schema = 1
    public var pid: Int32
    public var build: String
    /// `running` or `stopped` (written on shutdown).
    public var state: String
    public var startedAt: Date
    public var writtenAt: Date
    public var safeMode: Bool
    /// While in safe mode: when it ends by itself if the process keeps running (D16, 30 min).
    public var safeModeUntil: Date?
    /// This process was in safe mode and it ended after 30 min of stable running.
    public var safeModeClearedAt: Date?
    public var modes: Modes
    public var configProblems: [String]
    /// A daemon-wide problem, e.g. "OAuth-asiakas puuttuu".
    public var error: String?
    public var accounts: [AccountStatus]

    public init(pid: Int32, build: String, state: String = "running", startedAt: Date, writtenAt: Date, safeMode: Bool,
                safeModeUntil: Date? = nil, safeModeClearedAt: Date? = nil, modes: Modes, configProblems: [String] = [], error: String? = nil, accounts: [AccountStatus] = []) {
        self.pid = pid
        self.build = build
        self.state = state
        self.startedAt = startedAt
        self.writtenAt = writtenAt
        self.safeMode = safeMode
        self.safeModeUntil = safeModeUntil
        self.safeModeClearedAt = safeModeClearedAt
        self.modes = modes
        self.configProblems = configProblems
        self.error = error
        self.accounts = accounts
    }

    /// `status` exit codes (design §15).
    public enum Health: Int32, Sendable {
        case ok = 0
        case attention = 1
        case notRunning = 2
    }

    /// Stale after 3 min without a write ("daemon ei vastaa").
    public static let staleAfter: TimeInterval = 180

    public func health(now: Date) -> Health {
        if state != "running" || now.timeIntervalSince(writtenAt) > Self.staleAfter { return .notRunning }
        if safeMode || error != nil || !configProblems.isEmpty || accounts.contains(where: { $0.attention != nil }) {
            return .attention
        }
        return .ok
    }
}

public enum StatusFile {
    public static func write(_ status: DaemonStatus, to url: URL) throws {
        try AtomicFile.ensureDirectory(url.deletingLastPathComponent(), mode: 0o700)
        try AtomicFile.write(try DaemonJSON.encoder().encode(status), to: url, mode: 0o600)
    }

    /// nil when missing or unreadable.
    public static func read(_ url: URL) -> DaemonStatus? {
        guard let data = try? AtomicFile.read(url) else { return nil }
        return try? DaemonJSON.decoder().decode(DaemonStatus.self, from: data)
    }
}
