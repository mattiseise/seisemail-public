import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import DaemonCore
@testable import MailCore

// Shared support for the daemon suites (design phase2-daemon §17). Every construction of a DaemonCore type
// whose initializer §5 does not spell out lives here, so a signature change touches one file:
//   DaemonLog(sink:now:mirror:), DecisionLog(sink:), RuleSet.decode(_:), RuleSet.load(_:), DefaultRules.file,
//   CompiledRules.defaults, SentCache(capacity:), SentCache.record(_:at:me:), AccountStack's memberwise init,
//   Supervisor(paths:oauth:configStore:notifier:log:decisions:clock:safeMode:startedAt:build:makeStack:).

// MARK: - Time

/// Wall clock for daemon code. `now()` moves only when the test advances it; `sleep(until:)` parks until then.
/// With `autoAdvance`, a sleep jumps the clock to its deadline at once (pacing costs no real time).
/// Every requested deadline is kept in `requested`.
final class TestDaemonClock: DaemonClock, Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var autoAdvance: Bool
        var nextID = 0
        var sleepers: [Sleeper] = []
        var requested: [Date] = []
    }

    private let state: Mutex<State>

    init(_ start: Date, autoAdvance: Bool = false) {
        state = Mutex(State(now: start, autoAdvance: autoAdvance))
    }

    func now() -> Date { state.withLock { $0.now } }
    var requested: [Date] { state.withLock { $0.requested } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    var nextDeadline: Date? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    func setAutoAdvance(_ on: Bool) { state.withLock { $0.autoAdvance = on } }

    func sleep(until deadline: Date) async throws {
        let id = state.withLock { s in
            s.nextID += 1
            s.requested.append(deadline)
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { s in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= s.now { return .success(()) }
                    if s.autoAdvance {
                        s.now = deadline
                        return .success(())
                    }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) { advance(to: now().addingTimeInterval(seconds)) }

    /// Moves to `date` (never backwards) and wakes every sleeper whose deadline has passed, earliest first.
    func advance(to date: Date) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = max(s.now, date)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// A clock step (sleep, NTP): sets the time, also backwards, without waking anyone.
    func set(_ date: Date) { state.withLock { $0.now = date } }

    /// Moves to the earliest sleeper's deadline and wakes it; false if nobody sleeps.
    @discardableResult
    func advanceToNextDeadline() -> Bool {
        guard let next = nextDeadline else { return false }
        advance(to: next)
        return true
    }
}

/// 2026-10-05 09:00:30Z = 12:00:30 Helsinki (EEST, UTC+3), a Monday.
let daemonEpoch = D(1_791_190_830)

func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
}

/// An ISO 8601 date as the daemon writes it (with or without milliseconds).
func parseISO(_ text: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
}

func epoch(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }

/// JSON null for a missing value.
func orNull(_ value: Any?) -> Any { value ?? NSNull() }

// MARK: - Notifications

final class RecordingNotifier: DaemonNotifier, Sendable {
    private let log = Mutex<[DaemonEvent]>([])

    func post(_ e: DaemonEvent) async { log.withLock { $0.append(e) } }

    var events: [DaemonEvent] { log.withLock { $0 } }

    /// The `reminder` flag of every `.needsLogin`.
    var needsLogin: [Bool] {
        events.compactMap { e -> Bool? in
            if case .needsLogin(_, _, let reminder) = e { return reminder }
            return nil
        }
    }

    var renewed: Int {
        events.filter { e -> Bool in
            if case .renewed = e { return true }
            return false
        }.count
    }

    var resumedAfter: [TimeInterval] {
        events.compactMap { e -> TimeInterval? in
            if case .resumed(_, let after) = e { return after }
            return nil
        }
    }

    var expiresSoonHours: [Int] {
        events.compactMap { e -> Int? in
            if case .expiresSoon(_, _, let hours) = e { return hours }
            return nil
        }
    }

    var persistentErrorKinds: [String] {
        events.compactMap { e -> String? in
            if case .persistentError(_, let kind, _) = e { return kind }
            return nil
        }
    }
}

// MARK: - Probe base

/// The layer under `ProbeTransport` in tests: answers 200 `{}` with a `Date` header `serverOffset` seconds
/// ahead of the test clock (Gmail's clock), or the scripted status.
final class DateHeaderTransport: HTTPTransport, Sendable {
    private let clock: @Sendable () -> Date
    private let offset = Mutex<TimeInterval>(0)
    private let log = Mutex<[URLRequest]>([])

    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    var requests: [URLRequest] { log.withLock { $0 } }
    func setServerOffset(_ seconds: TimeInterval) { offset.withLock { $0 = seconds } }

    static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let server = clock().addingTimeInterval(offset.withLock { $0 })
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Date": Self.httpDate(server), "Content-Type": "application/json"])!
        return (Data("{}".utf8), response)
    }
}

func gmailRequest(_ method: String, _ path: String) -> URLRequest {
    var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!)
    r.httpMethod = method
    return r
}

// MARK: - Files

func posixMode(_ url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    return (attributes[.posixPermissions] as? NSNumber).map { $0.intValue & 0o777 }
}

func setPosixMode(_ url: URL, _ mode: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
}

func mtime(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

func setMTime(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

func jsonObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func jsonLines(_ url: URL) -> [[String: Any]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

/// SHA-256 of the refresh token, first 8 hex characters (design §5 `TokenFingerprint`).
func fingerprint(_ refreshToken: String) -> String {
    String(SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
}

// MARK: - Rules

enum Rules {
    static func defaultFixture() throws -> Data { try Fixture.data("daemon_rules_default") }

    /// Strict decoding plus compilation: the two steps `rules.json` goes through.
    static func compile(_ data: Data) throws -> CompiledRules {
        try RuleSet.load(data)
    }

    static func compile(_ json: String) throws -> CompiledRules { try compile(Data(json.utf8)) }

    /// The default file with the given rule ids enabled (or disabled) and `edit` applied to the JSON object.
    static func defaults(enabling: [String] = [], disabling: [String] = [],
                         edit: (inout [String: Any]) -> Void = { _ in }) throws -> CompiledRules {
        try compile(defaultsData(enabling: enabling, disabling: disabling, edit: edit))
    }

    static func defaultsData(enabling: [String] = [], disabling: [String] = [],
                             edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: defaultFixture()) as? [String: Any])
        var rules = try #require(object["rules"] as? [[String: Any]])
        for i in rules.indices {
            let id = rules[i]["id"] as? String ?? ""
            if enabling.contains(id) { rules[i]["enabled"] = true }
            if disabling.contains(id) { rules[i]["enabled"] = false }
        }
        object["rules"] = rules
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
}

func sentCache(_ addresses: [String], at date: Date = daemonEpoch, capacity: Int = 20_000) -> SentCache {
    var cache = SentCache(capacity: capacity)
    for address in addresses { cache.record([address], at: date) }
    return cache
}

// MARK: - Header threads for the pure planner

enum Mail {
    static let me = "matti@example.fi"

    static func msg(_ id: String, from: String = "Anna Ahola <anna@example.fi>", subject: String = "Hei",
                    labels: Set<String> = ["INBOX", "UNREAD"], at seconds: TimeInterval = 0,
                    headers: [String: String] = [:]) -> HeaderMessage {
        var all: [String: [String]] = ["from": [from], "subject": [subject], "to": [me]]
        for (name, value) in headers { all[name.lowercased(), default: []].append(value) }
        return HeaderMessage(id: id, labelIDs: labels, internalDate: daemonEpoch.addingTimeInterval(seconds), headers: all)
    }

    static func sent(_ id: String, to: String = "anna@example.fi", at seconds: TimeInterval = 0,
                     labels: Set<String> = ["SENT"]) -> HeaderMessage {
        HeaderMessage(id: id, labelIDs: labels, internalDate: daemonEpoch.addingTimeInterval(seconds),
                      headers: ["from": [me], "to": [to], "subject": ["Re: hei"]])
    }

    static func thread(_ id: String = "t1", _ messages: [HeaderMessage]) -> ThreadHeaders {
        ThreadHeaders(threadID: id, historyID: "2000", messages: messages)
    }
}

/// System labels plus the sorting labels with fixed IDs (Gmail resolves names case-insensitively).
enum Snap {
    static let uutiskirjeet = "L_U", ilmoitukset = "L_I", kuitit = "L_K", ihmiset = "L_H", marker = "L_M",
               vaatii = "L_V", omat = "L_O", kuititOstot = "L_KO", kuititTilaukset = "L_KT", superhuman = "L_S", torkku = "L_T"

    static let names: [String: String] = [
        uutiskirjeet: "Lajittelu/Uutiskirjeet", ilmoitukset: "Lajittelu/Ilmoitukset", kuitit: "Lajittelu/Kuitit",
        ihmiset: "Lajittelu/Ihmiset", marker: "Lajittelu/Luokiteltu", vaatii: "Lajittelu/Vaatii toimenpidettä",
        omat: "lajittelu/omat", kuititOstot: "kuitit/ostot", kuititTilaukset: "Kuitit/Tilaukset",
        superhuman: "[Superhuman]/AI/Marketing", torkku: "Torkku",
    ]

    static let snapshot = LabelSnapshot(labels: LabelFakeGmail.systemLabels
        + names.sorted { $0.key < $1.key }.map { GmailLabelInfo(id: $0.key, name: $0.value, kind: .user) })

    /// A snapshot with exactly these user labels (name → id).
    static func with(_ user: [String: String]) -> LabelSnapshot {
        LabelSnapshot(labels: LabelFakeGmail.systemLabels
            + user.sorted { $0.key < $1.key }.map { GmailLabelInfo(id: $0.value, name: $0.key, kind: .user) })
    }
}

func decide(_ thread: ThreadHeaders, new: Set<String>, labels: LabelSnapshot = Snap.snapshot,
            rules: CompiledRules = CompiledRules.defaults, sent: SentCache = SentCache(capacity: 20_000),
            me: Set<String> = [Mail.me]) -> (SortingDecision, decider: HeaderMessage?) {
    SortingPlanner.decide(thread: thread, newMessageIDs: new, labels: labels, rules: rules, sent: sent, me: me)
}

// MARK: - Account environment

/// One temporary daemon folder, one fake Gmail account and a runner factory. Stacks are built like
/// `AccountStack.make`, but over `SyncFakeGmail` (gated by `DaemonGmail` per mode) and the test clock.
final class DaemonEnv: Sendable {
    let email: String
    let root: URL
    let paths: DaemonPaths
    let clock: TestDaemonClock
    let notifier = RecordingNotifier()
    let oauth = OAuthConfig(clientID: "cid.apps.googleusercontent.com", clientSecret: "secret")
    let fake: SyncFakeGmail
    let configStore: ConfigStore
    let log: DaemonLog
    let decisions: DecisionLog
    let probeBase: DateHeaderTransport
    /// Token endpoint behind every stack's GoogleAuth; the fake Gmail never asks for a token.
    let tokenEndpoint = StubTransport { _ in (500, Data("{\"error\":\"server_error\"}".utf8)) }
    private let stacks = Mutex<[AccountStack]>([])
    private let shadow = Mutex<[ShadowWrite]>([])
    private let fileStamp = Mutex(0)

    init(email: String = "matti@example.fi", start: Date = daemonEpoch, autoAdvance: Bool = false) throws {
        self.email = email
        root = makeTempDir()
        paths = DaemonPaths(support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs"))
        let clock = TestDaemonClock(start, autoAdvance: autoAdvance)
        self.clock = clock
        fake = SyncFakeGmail(me: email, now: { clock.now() })
        probeBase = DateHeaderTransport(clock: { clock.now() })
        for dir in [paths.support, paths.daemon, paths.tokens, paths.requests, paths.logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        configStore = ConfigStore(paths: paths)
        log = DaemonLog(sink: RotatingFile(url: paths.logs.appendingPathComponent("daemon.log"), maxBytes: 5 << 20),
                        now: { clock.now() }, mirror: false)
        decisions = DecisionLog(sink: RotatingFile(url: paths.logs.appendingPathComponent("decisions.jsonl"), maxBytes: 10 << 20))
    }

    var decisionsURL: URL { paths.logs.appendingPathComponent("decisions.jsonl") }
    var logURL: URL { paths.logs.appendingPathComponent("daemon.log") }
    var decisionLines: [[String: Any]] { jsonLines(decisionsURL) }
    var logText: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    var builtStacks: [AccountStack] { stacks.withLock { $0 } }
    var latestStack: AccountStack? { builtStacks.last }
    var shadowWrites: [ShadowWrite] { shadow.withLock { $0 } }

    // MARK: Files

    /// Writes with a fresh, strictly increasing mtime, so a store that reloads on mtime change always sees it.
    func writeFile(_ data: Data, to url: URL, mode: Int = 0o644) throws {
        try data.write(to: url)
        try setPosixMode(url, mode)
        let n = fileStamp.withLock { s -> Int in
            s += 1
            return s
        }
        try setMTime(url, Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
    }

    func setConfig(wake: FeatureMode = .live, sorting: FeatureMode, _ edit: (inout DaemonConfig) -> Void = { _ in }) throws {
        var config = DaemonConfig()
        config.wake = wake
        config.sorting = sorting
        edit(&config)
        try writeFile(JSONEncoder().encode(config), to: paths.config)
    }

    func setRules(_ data: Data) throws { try writeFile(data, to: paths.rules) }

    /// `StoredToken` as `login` writes it. Default expiry: Monday 12.10.2026 9.12 Helsinki (consent 7 d − 10 min earlier).
    @discardableResult
    func writeToken(_ refresh: String = "r1", consentedAt: Date = D(1_791_181_320), refreshTokenExpiresAt: Date? = nil,
                    clientID: String? = nil, for account: String? = nil) throws -> StoredToken {
        let account = account ?? email
        let token = StoredToken(account: account, clientID: clientID ?? oauth.clientID, refreshToken: refresh,
                                consentedAt: consentedAt, refreshTokenExpiresAt: refreshTokenExpiresAt)
        try FileTokenStore.write(token, to: paths.token(account))
        return token
    }

    /// `state-<key>.json`, schema 1 (design §9.2), describing an account that is already running.
    func seedState(watermark: String = "1000", advancedAt: Date? = nil, coverageStart: Date? = nil,
                   sentBackfill: String = "done", backfillPageToken: String? = nil, backfillFetched: Int = 0,
                   sent: [String: Int] = [:], me: [String]? = nil, meCheckedAt: Date? = nil,
                   authStatus: String = "ok", since: Date? = nil, warned: [Int] = [], noteThreadIDs: [String] = [],
                   lastNotifiedAt: Date? = nil, scan: [String: Any]? = nil, sweepAt: Date? = nil,
                   schema: Int = 1, for account: String? = nil) throws {
        let account = account ?? email
        let now = clock.now()
        let token = try? FileTokenStore(fileURL: paths.token(account), readOnly: true).read()
        let auth: [String: Any] = [
            "status": authStatus, "warned": warned, "noteThreadIDs": noteThreadIDs,
            "lastNotifiedAt": orNull(lastNotifiedAt.map(iso)), "since": orNull(since.map(iso)),
            "fingerprint": orNull(token.map { fingerprint($0.refreshToken) }),
            "expiresAt": orNull(token.map { iso($0.expiresAt) }),
        ]
        let object: [String: Any] = [
            "schema": schema, "account": account, "createdAt": iso(now.addingTimeInterval(-86_400)), "writtenAt": iso(now),
            "watermark": ["historyId": watermark, "advancedAt": iso(advancedAt ?? now.addingTimeInterval(-60)),
                          "coverageStart": iso(coverageStart ?? now.addingTimeInterval(-86_400))],
            "scan": orNull(scan),
            "sentBackfill": ["phase": sentBackfill, "pageToken": orNull(backfillPageToken), "fetched": backfillFetched] as [String: Any],
            "sent": sent,
            "me": me ?? [account], "meCheckedAt": iso(meCheckedAt ?? now),
            "auth": auth,
            "sweepAt": iso(sweepAt ?? now), "shadowSince": iso(now.addingTimeInterval(-86_400)), "liveSince": NSNull(),
        ]
        try writeFile(JSONSerialization.data(withJSONObject: object), to: paths.state(account), mode: 0o600)
    }

    func state(for account: String? = nil) -> [String: Any]? { jsonObject(paths.state(account ?? email)) }

    var storedWatermark: String? { (state()?["watermark"] as? [String: Any])?["historyId"] as? String }
    var storedAuth: [String: Any]? { state()?["auth"] as? [String: Any] }
    var storedSent: [String: Any]? { state()?["sent"] as? [String: Any] }
    var storedBackfill: [String: Any]? { state()?["sentBackfill"] as? [String: Any] }

    /// One `backfill` request file (design §9.1: `{since, requestedAt}`).
    @discardableResult
    func requestBackfill(since: Date, for account: String? = nil) throws -> URL {
        let key = DaemonPaths.key(account ?? email)
        let url = paths.requests.appendingPathComponent("backfill-\(key)-\(Int(clock.now().timeIntervalSince1970)).json")
        try writeFile(JSONSerialization.data(withJSONObject: ["since": iso(since), "requestedAt": iso(clock.now())]), to: url, mode: 0o600)
        return url
    }

    // MARK: Stacks and runners

    func makeStack(_ account: String, _ config: DaemonConfig) -> AccountStack {
        let clock = self.clock
        let now: @Sendable () -> Date = { clock.now() }
        let tokens = FileTokenStore(fileURL: paths.token(account))
        let auth = GoogleAuth(config: oauth, store: tokens, transport: tokenEndpoint, now: now)
        let probe = ProbeTransport(base: probeBase, now: now)
        let client = LiveGmailClient(auth: auth, transport: probe, retry: RetryPolicy(delays: [], sleep: { _ in }))
        let record: @Sendable (ShadowWrite) -> Void = { [self] write in self.shadow.withLock { $0.append(write) } }
        func gated(_ mode: FeatureMode) -> DaemonGmail {
            DaemonGmail(fake, mode: mode == .shadow ? .shadow(record: record) : .live)
        }
        let wakeAPI = gated(config.wake)
        let sortAPI = gated(config.sorting)
        let noteAPI = DaemonGmail(fake, mode: .live)
        let wakeDirectory = LabelDirectory(api: wakeAPI)
        let sortDirectory = LabelDirectory(api: sortAPI)
        let stack = AccountStack(
            auth: auth, tokens: tokens, client: client, probe: probe,
            wakeAPI: wakeAPI, sortAPI: sortAPI, noteAPI: noteAPI,
            wakeDirectory: wakeDirectory, sortDirectory: sortDirectory,
            wakerCleaning: SnoozeWaker(api: wakeAPI, directory: wakeDirectory, options: SnoozeWaker.Options(cleansUp: true), now: now),
            wakerPlain: SnoozeWaker(api: wakeAPI, directory: wakeDirectory, options: SnoozeWaker.Options(cleansUp: false), now: now)
        )
        stacks.withLock { $0.append(stack) }
        return stack
    }

    func runner(for account: String? = nil) -> AccountRunner {
        AccountRunner(email: account ?? email, paths: paths, oauth: oauth, configStore: configStore, notifier: notifier,
                      log: log, decisions: decisions, clock: clock,
                      makeStack: { [self] account, config in self.makeStack(account, config) })
    }

    func supervisor(safeMode: Bool = false) -> Supervisor {
        let oauth = self.oauth
        return Supervisor(paths: paths, oauth: { oauth }, configStore: configStore, notifier: notifier, log: log,
                          decisions: decisions, clock: clock, safeMode: safeMode, startedAt: clock.now(), build: "92",
                          makeStack: { [self] account, _, config in self.makeStack(account, config) })
    }

    /// Measures skew on the newest stack's probe: one priced request answered with Gmail `aheadBy` seconds ahead.
    func measureSkew(aheadBy seconds: TimeInterval) async throws {
        let stack = try #require(latestStack)
        probeBase.setServerOffset(seconds)
        _ = try await stack.probe.send(gmailRequest("GET", "profile"))
    }

    // MARK: Fake helpers

    /// Thread `id` with one incoming newsletter message (List-Unsubscribe) in history.
    @discardableResult
    func newsletter(_ id: String, at date: Date? = nil) -> String {
        fake.deliver(id, from: "Uutiset <uutiset@lehti.fi>", subject: "Viikon uutiset",
                     headers: ["List-Unsubscribe": "<mailto:u@lehti.fi>"], at: date)
    }

    func labelID(_ name: String) -> String? { fake.labels.labelID(name) }

    var marker: String { SeiseLabels.Sorting.classifiedMarker }
}

/// Runs `tick` until `done` holds or `limit` ticks ran; returns the number of ticks.
@discardableResult
func tick(_ runner: AccountRunner, limit: Int = 5, until done: () -> Bool) async -> Int {
    for i in 1...limit {
        _ = await runner.syncTick()
        if done() { return i }
    }
    return limit
}

/// Drives `AccountRunner.run()` on a manual clock: waits until both loops sleep, moves to the earliest deadline,
/// and repeats until `done` holds (checked before each step) or `steps` deadlines passed.
func drive(_ clock: TestDaemonClock, sleepers: Int = 2, steps: Int = 12,
           until done: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0..<steps {
        if done() { return true }
        let _: Bool = await eventually { done() || clock.sleeperCount >= sleepers }
        if done() { return true }
        clock.advanceToNextDeadline()
    }
    return await eventually { done() }
}
