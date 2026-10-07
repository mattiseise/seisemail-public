import Foundation

/// `daemon/state-<key>.json`, schema 1 (design §9.2). Classification itself lives on the server (the
/// marker label), so losing this file is safe: the daemon starts again from "now" (§6.2).
public struct AccountState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public struct Watermark: Codable, Sendable, Equatable {
        /// Gmail `historyId`, a decimal string compared as UInt64.
        public var historyId: String
        /// When the watermark last moved.
        public var advancedAt: Date
        /// Mail older than this was never seen by the daemon (the sweep never reaches before it).
        public var coverageStart: Date

        public init(historyId: String, advancedAt: Date, coverageStart: Date) {
            self.historyId = historyId
            self.advancedAt = advancedAt
            self.coverageStart = coverageStart
        }
    }

    /// An inbox scan in progress (design §6.6); resumable from `pageToken`.
    public struct Scan: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case resync, backfill }
        /// Resync reads the sent folder first (`sent`), then the inbox (`inbox`). Backfill is inbox only.
        public enum Stage: String, Codable, Sendable { case sent, inbox }

        public var kind: Kind
        public var cutoff: Date
        /// Resync: the profile `historyId` read before scanning; the watermark when done.
        public var h0: String?
        public var pageToken: String?
        /// Backfill: the request file to delete when done (its name only).
        public var requestFile: String?
        public var stage: Stage
        /// Threads looked at so far, for the completion log line.
        public var threads: Int

        public init(kind: Kind, cutoff: Date, h0: String? = nil, pageToken: String? = nil, requestFile: String? = nil,
                    stage: Stage? = nil, threads: Int = 0) {
            self.kind = kind
            self.cutoff = cutoff
            self.h0 = h0
            self.pageToken = pageToken
            self.requestFile = requestFile
            self.stage = stage ?? (kind == .resync ? .sent : .inbox)
            self.threads = threads
        }

        private enum CodingKeys: String, CodingKey { case kind, cutoff, h0, pageToken, requestFile, stage, threads }

        /// `stage` and `threads` are additions to design §9.2 and may be missing: a resync then starts at the
        /// sent listing (re-reading sent mail is harmless), a backfill is inbox only.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(kind: try c.decode(Kind.self, forKey: .kind), cutoff: try c.decode(Date.self, forKey: .cutoff),
                      h0: try c.decodeIfPresent(String.self, forKey: .h0),
                      pageToken: try c.decodeIfPresent(String.self, forKey: .pageToken),
                      requestFile: try c.decodeIfPresent(String.self, forKey: .requestFile),
                      stage: try c.decodeIfPresent(Stage.self, forKey: .stage),
                      threads: try c.decodeIfPresent(Int.self, forKey: .threads) ?? 0)
        }
    }

    public struct SentBackfill: Codable, Sendable, Equatable {
        public enum Phase: String, Codable, Sendable { case pending, running, done }
        public var phase: Phase
        public var pageToken: String?
        public var fetched: Int

        public init(phase: Phase = .pending, pageToken: String? = nil, fetched: Int = 0) {
            self.phase = phase
            self.pageToken = pageToken
            self.fetched = fetched
        }
    }

    public struct Auth: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case ok, needsLogin }
        public var status: Status
        /// When `needsLogin` began.
        public var since: Date?
        /// Fingerprint of the token the fields below belong to.
        public var fingerprint: String?
        public var expiresAt: Date?
        /// Hours (of `notify.warnHours`) already warned for this expiry (a rotated refresh token keeps them). Written before the note is inserted.
        public var warned: [Int]
        /// Inserted expiry notes, archived after the next login.
        public var noteThreadIDs: [String]
        /// Last needsLogin notice (initial or daily reminder): the reminder throttle survives restarts.
        public var lastNotifiedAt: Date?

        public init(status: Status = .ok, since: Date? = nil, fingerprint: String? = nil, expiresAt: Date? = nil,
                    warned: [Int] = [], noteThreadIDs: [String] = [], lastNotifiedAt: Date? = nil) {
            self.status = status
            self.since = since
            self.fingerprint = fingerprint
            self.expiresAt = expiresAt
            self.warned = warned
            self.noteThreadIDs = noteThreadIDs
            self.lastNotifiedAt = lastNotifiedAt
        }
    }

    public var schema = AccountState.currentSchema
    public var account: String
    public var createdAt: Date
    public var writtenAt: Date
    public var watermark: Watermark
    public var scan: Scan?
    public var sentBackfill: SentBackfill
    public var sent: SentCache
    /// Own addresses (profile + send-as), lowercased.
    public var me: [String]
    public var meCheckedAt: Date
    public var auth: Auth
    public var sweepAt: Date?
    public var shadowSince: Date?
    public var liveSince: Date?

    public init(account: String, createdAt: Date, watermark: Watermark, scan: Scan? = nil,
                sentBackfill: SentBackfill = SentBackfill(), sent: SentCache = SentCache(), me: [String] = [],
                meCheckedAt: Date, auth: Auth = Auth(), sweepAt: Date? = nil, shadowSince: Date? = nil, liveSince: Date? = nil) {
        self.account = account.lowercased()
        self.createdAt = createdAt
        self.writtenAt = createdAt
        self.watermark = watermark
        self.scan = scan
        self.sentBackfill = sentBackfill
        self.sent = sent
        self.me = me
        self.meCheckedAt = meCheckedAt
        self.auth = auth
        self.sweepAt = sweepAt
        self.shadowSince = shadowSince
        self.liveSince = liveSince
    }

    /// The bootstrap state (design §6.2): watermark = the profile's `historyId`, coverage from now,
    /// sent backfill pending.
    public static func bootstrap(account: String, historyID: String, me: [String], now: Date) -> AccountState {
        AccountState(account: account, createdAt: now,
                     watermark: Watermark(historyId: historyID, advancedAt: now, coverageStart: now),
                     me: Array(Set(me.map { $0.lowercased() })).sorted(), meCheckedAt: now)
    }

    /// Equal apart from the watermark and `writtenAt`: the change may wait for the debounce (§9.3).
    func differsOnlyInWatermark(from other: AccountState) -> Bool {
        var a = self, b = other
        a.watermark = b.watermark
        a.writtenAt = b.writtenAt
        return a == b
    }

    /// `historyId` strings compared as UInt64 (non-numeric sort first).
    public static func historyID(_ a: String, isNewerThan b: String) -> Bool {
        (UInt64(a) ?? 0) > (UInt64(b) ?? 0)
    }
}
