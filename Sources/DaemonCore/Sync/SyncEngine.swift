import Foundation
import MailCore

/// What one sync tick works with: the sorter's mode-gated API and its own label directory (D10).
public struct SyncEnvironment: Sendable {
    public var api: any GmailSyncAPI
    public var directory: LabelDirectory
    /// `.shadow` or `.live` (`.off` never reaches the engine).
    public var mode: FeatureMode
    public var rules: CompiledRules
    public var config: DaemonConfig
    /// The sorting mode in effect now (`daemon.json`, safe mode). Asked at each page and before each write: a
    /// tick whose mode is no longer current stops at once (`mode sorting off` is the emergency stop). nil = never changes.
    public var currentMode: (@Sendable () async -> FeatureMode)?

    public init(api: any GmailSyncAPI, directory: LabelDirectory, mode: FeatureMode, rules: CompiledRules, config: DaemonConfig,
                currentMode: (@Sendable () async -> FeatureMode)? = nil) {
        self.api = api
        self.directory = directory
        self.mode = mode
        self.rules = rules
        self.config = config
        self.currentMode = currentMode
    }
}

public struct SyncCounts: Sendable, Equatable {
    public var threads = 0
    public var classified = 0
    public var propagated = 0
    public var unmatched = 0
    /// `threads.modify` calls made (or swallowed in shadow).
    public var writes = 0
    /// Threads given up after 3 failing ticks.
    public var skipped = 0

    public init() {}

    public mutating func add(_ other: SyncCounts) {
        threads += other.threads
        classified += other.classified
        propagated += other.propagated
        unmatched += other.unmatched
        writes += other.writes
        skipped += other.skipped
    }
}

public enum SyncResult: Sendable, Equatable {
    case ok
    /// Nothing ran (mode off, safe mode, phase); the reason is for status and log.
    case skipped(String)
    case offline
    case rateLimited
    /// `invalid_grant` / not signed in: the runner enters needsLogin.
    case signInExpired
    /// The token endpoint answered something else (5xx, `invalid_client`, unparsable): transient.
    case tokenEndpoint
    case failed(String)
    case cancelled
    /// The state file could not be written: no sorting writes until it can (design §10).
    case stateWriteFailed

    /// The `status.json` word.
    public var word: String {
        switch self {
        case .ok: "ok"
        case .skipped: "skipped"
        case .offline: "offline"
        case .rateLimited: "rateLimited"
        case .signInExpired: "signInExpired"
        case .tokenEndpoint: "tokenEndpoint"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .stateWriteFailed: "stateWriteFailed"
        }
    }

    /// Maps an error that ended a tick.
    public init(error: any Error) {
        if GmailFailure.isCancellation(error) {
            self = .cancelled
        } else if let e = error as? GmailError, e == .offline {
            self = .offline
        } else if GmailFailure.isRateLimited(error) {
            self = .rateLimited
        } else if let e = error as? AuthError {
            self = e == .invalidGrant || e == .notSignedIn ? .signInExpired : .tokenEndpoint
        } else if error is SyncEngine.StateWriteFailed {
            self = .stateWriteFailed
        } else {
            self = .failed(String(describing: error).prefix(200).description)
        }
    }
}

public struct SyncOutcome: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable { case sentBackfill, resync, backfill, replay }

    public var result: SyncResult
    public var counts: SyncCounts
    /// More work is waiting: the sync loop runs again at once instead of at the next minute.
    public var backlog: Bool
    public var stage: Stage?

    public init(result: SyncResult, counts: SyncCounts = SyncCounts(), backlog: Bool = false, stage: Stage? = nil) {
        self.result = result
        self.counts = counts
        self.backlog = backlog
        self.stage = stage
    }

    public static func skipped(_ reason: String) -> SyncOutcome { SyncOutcome(result: .skipped(reason)) }
}

/// `mak8r-daemon backfill` writes one of these into `daemon/requests/` (design §6.6); the daemon deletes it when done.
/// The file is `requests/backfill-<key>-<stamp>.json` with `{since, requestedAt}` (design §9.1): the account
/// comes from the file name.
public struct BackfillRequest: Sendable, Equatable {
    public var account: String
    public var since: Date
    public var requestedAt: Date

    public init(account: String, since: Date, requestedAt: Date) {
        self.account = account.lowercased()
        self.since = since
        self.requestedAt = requestedAt
    }

    private struct Body: Codable {
        var since: Date
        var requestedAt: Date
    }

    /// Writes the request file (0600) and returns its URL.
    @discardableResult
    public func write(paths: DaemonPaths) throws -> URL {
        let url = paths.backfillRequest(account, at: requestedAt)
        try AtomicFile.ensureDirectory(paths.requests, mode: 0o700)
        try AtomicFile.write(try DaemonJSON.encoder().encode(Body(since: since, requestedAt: requestedAt)), to: url, mode: 0o600)
        return url
    }

    /// Request files of `account`, oldest first.
    public static func pending(account: String, in directory: URL) -> [URL] {
        let prefix = "backfill-\(DaemonPaths.key(account))-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { DaemonPaths.isRequest($0, prefix: prefix) }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// The request in `url` (one of `pending(account:in:)`); nil when unreadable.
    public static func read(_ url: URL, account: String) -> BackfillRequest? {
        guard let data = try? AtomicFile.read(url),
              let body = try? DaemonJSON.decoder().decode(Body.self, from: data) else { return nil }
        return BackfillRequest(account: account, since: body.since, requestedAt: body.requestedAt)
    }

    /// `backfill --dry-run`: quota and time for `threads` inbox threads at the sorter's pace — one
    /// `threads.list` (10) per 100 threads, a fresh read (40) and at most one modify (10) each.
    public static func estimate(threads: Int, unitsPerMinute: Int = DaemonConfig.Sync().unitsPerMinute) -> (units: Int, minutes: Int) {
        let pages = max(1, (threads + SyncEngine.scanPageSize - 1) / SyncEngine.scanPageSize)
        let units = pages * 10 + threads * 50
        return (units, Int((Double(units) / Double(max(unitsPerMinute, 1))).rounded(.up)))
    }

    /// `--since 3d` (days back from `now`, Helsinki midnight) or `--since 2026-10-01` (Helsinki midnight).
    /// `date`'s Helsinki day as `--since` takes it ("2026-10-05"): parsed back it is that day's start, so a
    /// backfill from it covers `date` (at most a day of extra, idempotent work before it).
    public static func sinceArgument(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SnoozePresets.helsinki
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func parseSince(_ text: String, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SnoozePresets.helsinki
        if text.hasSuffix("d"), let days = Int(text.dropLast()), days > 0 {
            return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
        }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10 else { return nil }
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        guard let date, date <= now else { return nil }
        return date
    }
}

/// History replay, inbox scans (resync, backfill, sweep) and the sent-cache backfill for one account
/// (design §6.4–§6.7). Owns the account's state; every step checkpoints it, so cancellation or a crash
/// at any await leaves at most idempotent work to redo. Classification lives on the server (the marker),
/// so replaying a page never writes twice.
public actor SyncEngine {
    struct StateWriteFailed: Error {}
    /// The sorting mode changed during the tick: stop before the next write, keep the page's watermark.
    struct ModeChanged: Error {
        var from: FeatureMode
        var to: FeatureMode
    }
    public static let modeChangedReason = "modeChanged"

    public static let historyPageSize = 100
    public static let sentPageSize = 500
    public static let scanPageSize = 100
    public static let sweepCap = 25
    /// A thread whose page fails this many ticks is skipped so the watermark can move on.
    public static let maxThreadFailures = 3
    /// `me` is re-read after this long (profile + send-as, 2 units).
    public static let meRefreshInterval: TimeInterval = 86_400
    /// A read older than this when its write is due (a page of other work or a budget wait came between) is
    /// read again first, so a change Matti made meanwhile wins (conventions §1: fresh read just before the write).
    public static let freshReadWindow: TimeInterval = 5

    public let account: String
    public private(set) var state: AccountState
    private let store: StateStore
    private let budget: MinuteBudget
    private let decisions: DecisionLog
    private let log: DaemonLog
    private let clock: any DaemonClock
    private let requests: URL?
    /// Per-thread failures of the current replay page (in memory: a restart gives each thread 3 new tries).
    private var failures: [String: Int] = [:]
    /// Threads given up (3 failures) on the current replay page: done for it, never holding it back again.
    /// Cleared when the watermark moves (design §6.4 "at 3 → treat as done").
    private var givenUp: Set<String> = []

    /// `requests`: the folder backfill requests appear in (`DaemonPaths.requests`); nil = none.
    public init(account: String, state: AccountState, store: StateStore, budget: MinuteBudget, decisions: DecisionLog,
                log: DaemonLog, clock: any DaemonClock, requests: URL? = nil) {
        self.account = account.lowercased()
        self.state = state
        self.store = store
        self.budget = budget
        self.decisions = decisions
        self.log = log
        self.clock = clock
        self.requests = requests
    }

    // MARK: - State

    /// Changes the state in memory (the runner's auth fields); persisted by the next `save`.
    public func update(_ body: @Sendable (inout AccountState) -> Void) {
        body(&state)
    }

    /// Persists the state (watermark-only changes debounced unless `force`). False when the write failed.
    @discardableResult
    public func save(force: Bool = false) -> Bool {
        do {
            try store.save(state, force: force)
            return true
        } catch {
            log.error(account, "tilan tallennus epäonnistui: \(error)")
            return false
        }
    }

    /// The first run or a lost state file (design §6.2): watermark from the profile, coverage from now,
    /// `me` = profile + send-as, sent backfill pending. Classification is on the server, so this is safe.
    public static func bootstrap(account: String, api: any GmailSyncAPI, now: Date) async throws -> AccountState {
        let profile = try await api.profile()
        guard profile.email.lowercased() == account.lowercased() else {
            throw BootstrapError.wrongAccount(profile.email.lowercased())
        }
        let sendAs = (try? await api.sendAsSignatures().map(\.email)) ?? []
        return AccountState.bootstrap(account: account, historyID: profile.historyID, me: [profile.email] + sendAs, now: now)
    }

    public enum BootstrapError: Error, Equatable, Sendable {
        /// The token belongs to another Gmail account than its file name says.
        case wrongAccount(String)
    }

    // MARK: - Tick

    /// One sync tick after the runner's guards (§6.4): `me` refresh, the sent backfill (until done,
    /// nothing else), a pending backfill request or scan, history replay, and the sweep (live only).
    public func tick(_ env: SyncEnvironment) async -> SyncOutcome {
        var counts = SyncCounts()
        var stage: SyncOutcome.Stage?
        do {
            if store.lastSaveFailed, !save(force: true) { throw StateWriteFailed() }
            try await refreshMeIfDue(env)
            if state.sentBackfill.phase != .done {
                stage = .sentBackfill
                let done = try await sentBackfillStep(env)
                return SyncOutcome(result: .ok, counts: counts, backlog: !done, stage: stage)
            }
            pickUpBackfillRequest()
            var backlog = false
            if let kind = state.scan?.kind {
                stage = kind == .resync ? .resync : .backfill
                let done = try await scanStep(env, counts: &counts)
                if kind == .resync, !done {
                    return SyncOutcome(result: .ok, counts: counts, backlog: true, stage: stage)
                }
                backlog = !done
            }
            stage = stage ?? .replay
            backlog = try await replay(env, counts: &counts) || backlog
            try await sweepIfDue(env, counts: &counts)
            if !save() { throw StateWriteFailed() }
            return SyncOutcome(result: .ok, counts: counts, backlog: backlog, stage: stage)
        } catch let changed as ModeChanged {
            _ = save()
            log.notice(account, "lajittelun tila vaihtui kesken kierroksen (\(changed.from.rawValue) → \(changed.to.rawValue)): "
                + "keskeytetty, jatketaan uudessa tilassa")
            return SyncOutcome(result: .skipped(Self.modeChangedReason), counts: counts, backlog: false, stage: stage)
        } catch {
            _ = save()
            return SyncOutcome(result: SyncResult(error: error), counts: counts, backlog: false, stage: stage)
        }
    }

    /// Throws `ModeChanged` when the sorting mode in effect is no longer the one this tick runs in.
    private func checkMode(_ env: SyncEnvironment) async throws {
        guard let currentMode = env.currentMode else { return }
        let now = await currentMode()
        if now != env.mode { throw ModeChanged(from: env.mode, to: now) }
    }

    // MARK: - Replay (§6.4)

    /// Replays history from the watermark, page by page. Returns true when a resync was started (backlog).
    ///
    /// Each thread is read, decided and written in turn, so a write never rests on a read made before other
    /// threads' work (conventions §1). Threads with a new SENT message (or no label hint) are read first, so
    /// "SENT and incoming in one batch" already counts for rule 4; `process` reads such a thread again if that
    /// read is no longer fresh when its write is due.
    @discardableResult
    public func replay(_ env: SyncEnvironment, counts: inout SyncCounts) async throws -> Bool {
        let start = state.watermark.historyId
        var token: String?
        repeat {
            try await checkMode(env)
            try await budget.spend(2)
            let page: HistoryPage
            do {
                page = try await env.api.history(startHistoryID: start, pageToken: token, maxResults: Self.historyPageSize)
            } catch GmailSyncError.historyExpired {
                try await startResync(env)
                return true
            }
            let (order, newIDs, sentFirst) = Self.group(page.added)
            var retryPage = false
            var early: [String: (thread: ThreadHeaders, at: Date)] = [:]
            var done: Set<String> = givenUp
            // Sent addresses first.
            for id in order where sentFirst.contains(id) && !done.contains(id) {
                do {
                    try await budget.spend(40)
                    let thread = try await env.api.threadHeaders(id: id, headers: DaemonHeaders.thread)
                    early[id] = (thread, clock.now())
                    recordSent(thread, only: newIDs[id] ?? [])
                } catch let error where GmailFailure.isNotFound(error) {
                    done.insert(id)                            // deleted meanwhile
                } catch let error where GmailFailure.abortsPass(error) {
                    throw error
                } catch {
                    done.insert(id)
                    if noteFailure(id, error, counts: &counts) { retryPage = true }
                }
            }
            for id in order where !done.contains(id) {
                do {
                    let thread: ThreadHeaders
                    let readAt: Date
                    if let read = early[id] {
                        (thread, readAt) = read
                    } else {
                        try await budget.spend(40)
                        thread = try await env.api.threadHeaders(id: id, headers: DaemonHeaders.thread)
                        readAt = clock.now()
                        recordSent(thread, only: newIDs[id] ?? [])
                    }
                    try await process(thread, readAt: readAt, newIDs: newIDs[id] ?? [], env: env, reason: nil, counts: &counts)
                } catch let error where GmailFailure.isNotFound(error) {
                    continue                                   // deleted meanwhile
                } catch let error where GmailFailure.abortsPass(error) || error is StateWriteFailed || error is ModeChanged {
                    throw error
                } catch {
                    if noteFailure(id, error, counts: &counts) { retryPage = true }
                }
            }
            if retryPage {
                // The watermark stays: the page replays next tick (idempotent).
                return false
            }
            for id in order { failures[id] = nil }
            givenUp = []
            let next = page.nextPageToken == nil ? page.historyID : (page.lastRecordID ?? state.watermark.historyId)
            advanceWatermark(to: next)
            if !save() { throw StateWriteFailed() }
            token = page.nextPageToken
        } while token != nil
        return false
    }

    /// Thread IDs in first-seen order, each thread's new message IDs, and the threads to read first for the
    /// sent cache (a new SENT message, or no hint). Refs whose hint labels say DRAFT/SPAM/TRASH/CHAT are
    /// dropped; SENT stays (the sent cache needs it).
    static func group(_ added: [AddedMessage]) -> (order: [String], newIDs: [String: Set<String>], sentFirst: Set<String>) {
        let dropped: Set<String> = [SeiseLabels.draft, SeiseLabels.spam, GmailLabel.trash, SeiseLabels.chat]
        var order: [String] = []
        var newIDs: [String: Set<String>] = [:]
        var sentFirst: Set<String> = []
        for ref in added {
            if let hint = ref.labelIDs, !hint.isDisjoint(with: dropped) { continue }
            if newIDs[ref.threadID] == nil { order.append(ref.threadID) }
            newIDs[ref.threadID, default: []].insert(ref.id)
            if ref.labelIDs?.contains(SeiseLabels.sent) ?? true { sentFirst.insert(ref.threadID) }
        }
        return (order, newIDs, sentFirst)
    }

    /// Counts a per-thread failure; true while the thread deserves another try (< 3 ticks).
    private func noteFailure(_ threadID: String, _ error: any Error, counts: inout SyncCounts) -> Bool {
        let n = (failures[threadID] ?? 0) + 1
        failures[threadID] = n
        if n >= Self.maxThreadFailures {
            log.error(account, "ketju \(threadID) ohitettu \(n) epäonnistuneen kierroksen jälkeen: \(Self.describe(error))")
            failures[threadID] = nil
            givenUp.insert(threadID)
            counts.skipped += 1
            return false
        }
        log.notice(account, "ketju \(threadID) epäonnistui (\(n)/\(Self.maxThreadFailures)): \(Self.describe(error))")
        return true
    }

    private func advanceWatermark(to historyID: String) {
        guard historyID != state.watermark.historyId else { return }
        guard AccountState.historyID(historyID, isNewerThan: state.watermark.historyId) else { return }
        state.watermark.historyId = historyID
        state.watermark.advancedAt = clock.now()
    }

    /// SENT messages among `ids` (all when nil) → their To and Cc, minus me.
    private func recordSent(_ thread: ThreadHeaders, only ids: Set<String>?, since cutoff: Date? = nil) {
        let me = Set(state.me)
        for m in thread.messages where m.labelIDs.contains(SeiseLabels.sent) {
            if let ids, !ids.contains(m.id) { continue }
            if let cutoff, (m.internalDate ?? .distantPast) < cutoff { continue }
            recordRecipients(m, me: me)
        }
    }

    private func recordRecipients(_ m: HeaderMessage, me: Set<String>) {
        let addresses = DaemonHeaders.recipients.flatMap { m.all($0) }.flatMap { MessageFacts.addresses($0, excluding: me) }
        guard !addresses.isEmpty else { return }
        state.sent.record(addresses, at: m.internalDate ?? clock.now(), me: me)
    }

    /// Decide and (when due) write one fresh thread; logs the decision in both modes. A read older than
    /// `freshReadWindow` when the write is due is read again and re-decided first. A sweep's re-evaluation
    /// that writes nothing is neither counted nor logged: the thread was (or will be) decided by history.
    private func process(_ first: ThreadHeaders, readAt: Date, newIDs: Set<String>, env: SyncEnvironment, reason: String?,
                         counts: inout SyncCounts) async throws {
        let me = Set(state.me)
        let rules = env.rules
        var thread = first
        var (decision, decider) = try await decide(thread, newIDs: newIDs, env: env)
        if !decision.addNames.isEmpty {
            if env.mode == .live, store.lastSaveFailed { throw StateWriteFailed() }
            try await budget.spend(10)
            if clock.now().timeIntervalSince(readAt) > Self.freshReadWindow {
                try await budget.spend(40)
                thread = try await env.api.threadHeaders(id: thread.threadID, headers: DaemonHeaders.thread)
                (decision, decider) = try await decide(thread, newIDs: newIDs, env: env)
            }
        }
        if reason == "sweep", decision.addNames.isEmpty { return }
        counts.threads += 1
        decisions.append(DecisionEntry(at: clock.now(), mode: env.mode, account: account, thread: thread,
                                       decision: decision, decider: decider, reason: reason))
        switch decision {
        case .classify: counts.classified += 1
        case .propagate(let names) where !names.isEmpty: counts.propagated += 1
        case .unmatched: counts.unmatched += 1
        default: break
        }
        guard !decision.addNames.isEmpty else { return }
        try await checkMode(env)
        let sent = state.sent
        let writer = LabelWriter(api: env.api, directory: env.directory)
        let added = try await writer.apply(decision, thread: thread) { fresh, snap in
            SortingPlanner.decide(thread: fresh, newMessageIDs: newIDs, labels: snap, rules: rules, sent: sent, me: me).0
        }
        if !added.isEmpty { counts.writes += 1 }
    }

    private func decide(_ thread: ThreadHeaders, newIDs: Set<String>, env: SyncEnvironment) async throws
        -> (SortingDecision, decider: HeaderMessage?) {
        let snapshot = try await env.directory.snapshot(knowing: thread.labelIDs)
        return SortingPlanner.decide(thread: thread, newMessageIDs: newIDs, labels: snapshot, rules: env.rules,
                                     sent: state.sent, me: Set(state.me))
    }

    // MARK: - Scans (§6.6)

    /// A history 404: take `H0` first, then scan sent and inbox from the cutoff; `W = H0` when done.
    private func startResync(_ env: SyncEnvironment) async throws {
        try await budget.spend(1)
        let profile = try await env.api.profile()
        let now = clock.now()
        let cutoff = max(state.watermark.advancedAt.addingTimeInterval(-3_600),
                         now.addingTimeInterval(-Double(env.config.sync.resyncMaxDays) * 86_400))
        state.scan = AccountState.Scan(kind: .resync, cutoff: cutoff, h0: profile.historyID)
        log.notice(account, "historia vanhentunut (404): uudelleensynkronointi alkaen \(DaemonLog.utcMinute(cutoff))")
        if !save(force: true) { throw StateWriteFailed() }
    }

    /// Starts a backfill for the oldest request file, unless a scan is already running.
    private func pickUpBackfillRequest() {
        guard state.scan == nil, let requests else { return }
        for url in BackfillRequest.pending(account: account, in: requests) {
            guard let request = BackfillRequest.read(url, account: account) else {
                log.error(account, "virheellinen backfill-pyyntö \(url.lastPathComponent) poistettu")
                try? FileManager.default.removeItem(at: url)
                continue
            }
            state.scan = AccountState.Scan(kind: .backfill, cutoff: request.since, requestFile: url.lastPathComponent)
            log.notice(account, "backfill alkaa \(DaemonLog.utcMinute(request.since)) alkaen")
            _ = save(force: true)
            return
        }
    }

    /// Starts a backfill directly (tests, `once`). Ignored while another scan runs.
    public func startBackfill(since: Date, requestFile: String? = nil) {
        guard state.scan == nil else { return }
        state.scan = AccountState.Scan(kind: .backfill, cutoff: since, requestFile: requestFile)
    }

    /// One page of the running scan. True when the scan finished.
    @discardableResult
    public func scanStep(_ env: SyncEnvironment, counts: inout SyncCounts) async throws -> Bool {
        guard var scan = state.scan else { return true }
        try await checkMode(env)
        let epoch = Int(scan.cutoff.timeIntervalSince1970)
        switch scan.stage {
        case .sent:
            try await budget.spend(5)
            let page = try await env.api.listMessageIDs(query: "in:sent after:\(epoch)", pageToken: scan.pageToken,
                                                        maxResults: Self.sentPageSize)
            try await fetchRecipients(page.ids, env: env)
            scan.pageToken = page.nextPageToken
            if scan.pageToken == nil { scan.stage = .inbox }
            state.scan = scan
            if !save(force: true) { throw StateWriteFailed() }
            return false
        case .inbox:
            try await budget.spend(10)
            let page = try await env.api.listThreads(query: "in:inbox after:\(epoch)", pageToken: scan.pageToken,
                                                     maxResults: Self.scanPageSize)
            for id in page.ids {
                try await scanThread(id, cutoff: scan.cutoff, env: env, reason: scan.kind.rawValue, counts: &counts)
            }
            scan.threads += page.ids.count
            scan.pageToken = page.nextPageToken
            guard scan.pageToken == nil else {
                state.scan = scan
                if !save(force: true) { throw StateWriteFailed() }
                return false
            }
            finish(scan)
            if !save(force: true) { throw StateWriteFailed() }
            return true
        }
    }

    private func finish(_ scan: AccountState.Scan) {
        state.scan = nil
        switch scan.kind {
        case .resync:
            if let h0 = scan.h0 {
                state.watermark.historyId = h0
                state.watermark.advancedAt = clock.now()
            }
            failures = [:]
            givenUp = []
            log.notice(account, "uudelleensynkronointi valmis: ketjuja \(scan.threads), vesileima \(scan.h0 ?? "-")")
        case .backfill:
            if let name = scan.requestFile, let requests {
                try? FileManager.default.removeItem(at: requests.appendingPathComponent(name))
            }
            log.notice(account, "backfill valmis: ketjuja \(scan.threads)")
        }
    }

    /// One thread of an inbox scan: messages from the cutoff on count as new. Per-thread errors are
    /// logged and skipped (a scan is a catch-up, not the exact path); aborting errors end the step.
    private func scanThread(_ id: String, cutoff: Date, env: SyncEnvironment, reason: String, counts: inout SyncCounts) async throws {
        do {
            try await budget.spend(40)
            let thread = try await env.api.threadHeaders(id: id, headers: DaemonHeaders.thread)
            let readAt = clock.now()
            let newIDs = Set(thread.messages.filter { ($0.internalDate ?? .distantPast) >= cutoff }.map(\.id))
            recordSent(thread, only: nil, since: cutoff)
            try await process(thread, readAt: readAt, newIDs: newIDs, env: env, reason: reason, counts: &counts)
        } catch let error where GmailFailure.isNotFound(error) {
            return
        } catch let error where GmailFailure.abortsPass(error) || error is StateWriteFailed || error is ModeChanged {
            throw error
        } catch {
            log.error(account, "\(reason): ketju \(id) ohitettu: \(Self.describe(error))")
            counts.skipped += 1
        }
    }

    /// The live-mode sweep (every `sweepMinutes`): recent inbox threads without the marker, at most 25.
    /// Skipped while the marker label is unconfirmed: Gmail answers a `-label:` on a missing label with nothing.
    public func sweepIfDue(_ env: SyncEnvironment, counts: inout SyncCounts) async throws {
        guard env.mode == .live else { return }
        let now = clock.now()
        if let last = state.sweepAt, now.timeIntervalSince(last) < Double(env.config.sync.sweepMinutes) * 60 { return }
        let marker = SeiseLabels.Sorting.classifiedMarker
        guard let markerID = try await env.directory.snapshot().id(forName: marker),
              !markerID.hasPrefix(DaemonGmail.shadowIDPrefix) else { return }
        let cutoff = max(state.watermark.coverageStart, now.addingTimeInterval(-Double(env.config.sync.sweepWindowHours) * 3_600))
        let query = "in:inbox after:\(Int(cutoff.timeIntervalSince1970)) -\(SearchSyntax.label(marker))"
        try await budget.spend(10)
        let page = try await env.api.listThreads(query: query, pageToken: nil, maxResults: Self.sweepCap)
        for id in page.ids.prefix(Self.sweepCap) {
            try await scanThread(id, cutoff: cutoff, env: env, reason: "sweep", counts: &counts)
        }
        state.sweepAt = now
    }

    // MARK: - Sent backfill (§6.7)

    /// One page of the sent-cache backfill. True when done (listing exhausted or the cap reached).
    @discardableResult
    public func sentBackfillStep(_ env: SyncEnvironment) async throws -> Bool {
        guard state.sentBackfill.phase != .done else { return true }
        let cap = env.config.sentBackfill.maxMessages
        var progress = state.sentBackfill
        guard progress.fetched < cap else {
            progress.phase = .done
            state.sentBackfill = progress
            if !save(force: true) { throw StateWriteFailed() }
            return true
        }
        try await budget.spend(5)
        let page = try await env.api.listMessageIDs(query: "in:sent newer_than:\(env.config.sentBackfill.days)d",
                                                    pageToken: progress.pageToken,
                                                    maxResults: min(Self.sentPageSize, cap - progress.fetched))
        let ids = Array(page.ids.prefix(cap - progress.fetched))
        try await fetchRecipients(ids, env: env)
        progress.fetched += ids.count
        progress.pageToken = page.nextPageToken
        let done = page.nextPageToken == nil || progress.fetched >= cap
        progress.phase = done ? .done : .running
        state.sentBackfill = progress
        if done { log.notice(account, "lähetettyjen välimuisti valmis: viestejä \(progress.fetched), osoitteita \(state.sent.count)") }
        if !save(force: true) { throw StateWriteFailed() }
        return done
    }

    /// `messages.get?format=metadata` (To, Cc) for each id into the sent cache. Per-message errors skip it.
    private func fetchRecipients(_ ids: [String], env: SyncEnvironment) async throws {
        let me = Set(state.me)
        for id in ids {
            do {
                try await budget.spend(20)
                let message = try await env.api.messageHeaders(id: id, headers: DaemonHeaders.recipients)
                recordRecipients(message, me: me)
            } catch let error where GmailFailure.isNotFound(error) {
                continue
            } catch let error where GmailFailure.abortsPass(error) {
                throw error
            } catch {
                log.notice(account, "lähetetty viesti \(id) ohitettu: \(Self.describe(error))")
            }
        }
    }

    // MARK: - me

    /// Re-reads own addresses (profile + send-as) once a day; they never count as "people".
    public func refreshMeIfDue(_ env: SyncEnvironment) async throws {
        let now = clock.now()
        guard now.timeIntervalSince(state.meCheckedAt) >= Self.meRefreshInterval else { return }
        try await budget.spend(2)
        let profile = try await env.api.profile()
        let sendAs = try await env.api.sendAsSignatures().map(\.email)
        let me = Set(([profile.email] + sendAs).map { $0.lowercased() })
        state.me = me.sorted()
        state.sent.remove(me)
        state.meCheckedAt = now
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? GmailError, case .http(let status, _) = e { return "HTTP \(status)" }   // never the body
        return String(describing: error).prefix(120).description
    }
}
