import Foundation
import MailCore

/// One account's Gmail stack, rebuilt when the token fingerprint or a mode changes (D6, D10).
/// Transport: `LiveGmailClient → read cache → quota (.daemon, 3,000/min) → ProbeTransport → URLSession`.
public struct AccountStack: Sendable {
    public let auth: GoogleAuth
    public let tokens: FileTokenStore
    public let client: LiveGmailClient
    public let probe: ProbeTransport
    /// Gated per mode; `noteAPI` is always live (expiry notes go out in every mode).
    public let wakeAPI: DaemonGmail, sortAPI: DaemonGmail, noteAPI: DaemonGmail
    /// Separate caches: a shadow sorter's pretend labels never reach the waker.
    public let wakeDirectory: LabelDirectory, sortDirectory: LabelDirectory
    /// `Options(cleansUp: true/false)` over the same `wakeDirectory`; each tick picks one (V11, D15).
    public let wakerCleaning: SnoozeWaker, wakerPlain: SnoozeWaker

    public init(auth: GoogleAuth, tokens: FileTokenStore, client: LiveGmailClient, probe: ProbeTransport,
                wakeAPI: DaemonGmail, sortAPI: DaemonGmail, noteAPI: DaemonGmail,
                wakeDirectory: LabelDirectory, sortDirectory: LabelDirectory,
                wakerCleaning: SnoozeWaker, wakerPlain: SnoozeWaker) {
        self.auth = auth
        self.tokens = tokens
        self.client = client
        self.probe = probe
        self.wakeAPI = wakeAPI
        self.sortAPI = sortAPI
        self.noteAPI = noteAPI
        self.wakeDirectory = wakeDirectory
        self.sortDirectory = sortDirectory
        self.wakerCleaning = wakerCleaning
        self.wakerPlain = wakerPlain
    }

    /// Production wiring for `email`.
    public static func make(email: String, oauth: OAuthConfig, paths: DaemonPaths, config: DaemonConfig, log: DaemonLog? = nil,
                            shadowRecord: @escaping @Sendable (ShadowWrite) -> Void) -> AccountStack {
        var report: (@Sendable (String) -> Void)?
        if let log { report = { message in log.error(email, message) } }
        let tokens = FileTokenStore(fileURL: paths.token(email), report: report)
        let auth = GoogleAuth(config: oauth, store: tokens, transport: URLSessionTransport())
        let probe = ProbeTransport(now: { Date() })
        let client = LiveGmailClient(auth: auth, transport: GmailTransports.live(policy: .daemon, base: probe))
        return assemble(auth: auth, tokens: tokens, client: client, probe: probe, base: client, config: config,
                        shadowRecord: shadowRecord, now: { Date() })
    }

    /// Gates, directories and wakers over `base` (normally `client`; tests pass a fake).
    public static func assemble(auth: GoogleAuth, tokens: FileTokenStore, client: LiveGmailClient, probe: ProbeTransport,
                                base: any GmailSyncAPI, config: DaemonConfig,
                                shadowRecord: @escaping @Sendable (ShadowWrite) -> Void,
                                now: @escaping @Sendable () -> Date) -> AccountStack {
        func gate(_ mode: FeatureMode) -> DaemonGmail {
            DaemonGmail(base, mode: mode == .live ? .live : .shadow(record: shadowRecord))
        }
        let wakeAPI = gate(config.wake)
        let sortAPI = gate(config.sorting)
        let wakeDirectory = LabelDirectory(api: wakeAPI)
        return AccountStack(
            auth: auth, tokens: tokens, client: client, probe: probe,
            wakeAPI: wakeAPI, sortAPI: sortAPI, noteAPI: DaemonGmail(base, mode: .live),
            wakeDirectory: wakeDirectory, sortDirectory: LabelDirectory(api: sortAPI),
            wakerCleaning: SnoozeWaker(api: wakeAPI, directory: wakeDirectory, options: .init(cleansUp: true), now: now),
            wakerPlain: SnoozeWaker(api: wakeAPI, directory: wakeDirectory, options: .init(cleansUp: false), now: now)
        )
    }
}

public enum LoginReason: String, Sendable, Equatable {
    case expired, tokenMissing, tokenUnreadable, clientChanged
    /// The token belongs to another Gmail account than its file name.
    case wrongAccount
}

public enum AccountPhase: Sendable, Equatable {
    case starting, backfillingSent, running
    case needsLogin(since: Date, reason: LoginReason)
    /// Future state schema (or another unusable state): the account is left untouched.
    case stateError(String)

    /// The `status.json` word.
    public var word: String {
        switch self {
        case .starting: "starting"
        case .backfillingSent: "backfillingSent"
        case .running: "running"
        case .needsLogin: "needsLogin"
        case .stateError: "stateError"
        }
    }

    /// Wakes and sync run only here.
    public var isActive: Bool { self == .running || self == .backfillingSent }

    public var isNeedsLogin: Bool {
        if case .needsLogin = self { return true }
        return false
    }
}

/// One account: the wake loop at mm:02 and the sync loop at mm:20 (D8), sharing one stack and one
/// quota (design §6.2–§6.4, §8.3). Never throws and never exits the process: `invalid_grant` parks the
/// account in needsLogin (state kept) until a new token file appears.
public actor AccountRunner {
    public static let idlePoll: TimeInterval = 30
    public static let wakeOffset: TimeInterval = 2
    public static let syncOffset: TimeInterval = 20
    /// The live sorter re-lists labels this often, so a label renamed in Gmail (same ID) is seen by name.
    public static let labelRefreshInterval: TimeInterval = 300

    public let email: String
    private let paths: DaemonPaths
    private let oauth: OAuthConfig
    private let configStore: ConfigStore
    private let notifier: any DaemonNotifier
    private let log: DaemonLog
    private let decisions: DecisionLog
    private let clock: any DaemonClock
    private let makeStack: @Sendable (String, DaemonConfig) -> AccountStack
    /// D16: sorting is skipped while active; the supervisor ends it after 30 min of stable running.
    private let safeMode: SafeMode
    private let onChange: (@Sendable () async -> Void)?

    public private(set) var phase: AccountPhase = .starting
    private var stack: AccountStack?
    private var stackKey: StackKey?
    private var stackGeneration = 0
    private var labelsEnsuredGeneration = -1
    /// When the live sorter's label directory was last listed (a new stack lists on first use).
    private var sortLabelsListedAt: Date?
    private var engine: SyncEngine?
    private let budget: MinuteBudget
    private var isPreparing = false
    /// A needsLogin poll is running (both loops poll; actor reentrancy must not double a resume or a reminder).
    private var isPolling = false
    /// The token file's fingerprint when needsLogin began; a different one resumes.
    private var needsLoginFingerprint: TokenFingerprint?
    private var notifiedWithoutState = false
    /// `doPrepare` found a persisted needsLogin with another token and resumed (posted `.resumed`, archived).
    private var resumedInPrepare = false
    private var lastProblems: [String] = []

    // Status
    private var lastWakeAt: Date?
    private var lastWakeResult: String?
    private var nextWakeAt: Date?
    private var lastSyncAt: Date?
    private var lastSyncResult: String?
    private var today = AccountStatus.Today()
    private var todayStart: Date?
    private var lastHeartbeat: Date?
    private var hourUnits = 0

    // Persistent-error throttles (design §10).
    private var offline = PersistentErrorTracker(after: 6 * 3_600)
    private var rateLimited = PersistentErrorTracker(after: 3_600)
    private var tokenEndpoint = PersistentErrorTracker(after: 3_600)
    private var skew = PersistentErrorTracker(after: 3_600)
    private var stateWrite = PersistentErrorTracker(after: 0)
    /// Per-thread failures in 30 consecutive sync ticks.
    private var failingTicks = PersistentErrorTracker(after: 0, afterCount: 30)
    /// Shadow wake log lines: each thread at most once per hour.
    private var shadowWakeSeen: [String: Date] = [:]

    private struct StackKey: Equatable {
        var fingerprint: TokenFingerprint?
        var wake: FeatureMode
        var sorting: FeatureMode
    }

    public init(email: String, paths: DaemonPaths, oauth: OAuthConfig, configStore: ConfigStore,
                notifier: any DaemonNotifier, log: DaemonLog, decisions: DecisionLog, clock: any DaemonClock,
                makeStack: @escaping @Sendable (String, DaemonConfig) -> AccountStack,
                safeMode: SafeMode? = nil, onChange: (@Sendable () async -> Void)? = nil) {
        self.email = email.lowercased()
        self.paths = paths
        self.oauth = oauth
        self.configStore = configStore
        self.notifier = notifier
        self.log = log
        self.decisions = decisions
        self.clock = clock
        self.makeStack = makeStack
        self.safeMode = safeMode ?? SafeMode(active: false, since: .distantPast)
        self.onChange = onChange
        self.budget = MinuteBudget(unitsPerMinute: DaemonConfig().sync.unitsPerMinute, clock: clock)
    }

    // MARK: - Loops

    /// Wake and sync loops until cancelled; then the state is saved.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wakeLoop() }
            group.addTask { await self.syncLoop() }
        }
        await shutdown()
    }

    private func wakeLoop() async {
        while !Task.isCancelled {
            let now = clock.now()
            if !phase.isActive, phase != .starting {
                if (try? await clock.sleep(until: now.addingTimeInterval(Self.idlePoll))) == nil { return }
                if phase.isNeedsLogin { await pollWhileNeedsLogin() }
                continue
            }
            if (try? await clock.sleep(until: DaemonSchedule.nextMinute(after: now, offset: Self.wakeOffset))) == nil { return }
            _ = await wakeTick()
        }
    }

    private func syncLoop() async {
        var backlog = false
        while !Task.isCancelled {
            let now = clock.now()
            if phase.isNeedsLogin {
                if (try? await clock.sleep(until: now.addingTimeInterval(Self.idlePoll))) == nil { return }
                await pollWhileNeedsLogin()
                // Resumed: tick at once (wakes and replay of the pause), then back to the minute rhythm.
                backlog = phase.isActive
                continue
            }
            if case .stateError = phase {
                if (try? await clock.sleep(until: now.addingTimeInterval(60))) == nil { return }
                continue
            }
            if !backlog {
                if (try? await clock.sleep(until: DaemonSchedule.nextMinute(after: now, offset: Self.syncOffset))) == nil { return }
            }
            let outcome = await syncTick()
            backlog = outcome.backlog && outcome.result == .ok
        }
    }

    private func shutdown() async {
        if let engine { await engine.save(force: true) }
        log.info(email, "pysäytetty")
    }

    // MARK: - Wake (§6.3)

    public func wakeTick() async -> WakeOutcome {
        // §8.3: both loops poll the token file while needsLogin, so wakes due meanwhile fire on the first tick.
        if phase.isNeedsLogin { await pollWhileNeedsLogin() }
        let (config, _, _) = await configStore.current()
        guard config.wake != .off else { return .skipped }
        guard await prepare() else {
            if phase.isNeedsLogin { return .paused }
            if case .stateError = phase { return .failed }
            return .skipped
        }
        await checkStack(config)
        guard phase.isActive, let stack else { return .paused }
        let now = clock.now()
        let cleaning = config.wake == .live && stack.probe.skewAllowsCleanup(now: now)
        let waker = cleaning ? stack.wakerCleaning : stack.wakerPlain
        let unitsBefore = stack.probe.totalUnits
        let outcome: WakeOutcome
        var failure: (any Error)?
        do {
            let report = try await waker.runOnce()
            outcome = WakeOutcome(report: report)
            recordWake(report, mode: config.wake, units: stack.probe.totalUnits - unitsBefore, at: now)
        } catch {
            outcome = WakeOutcome(error: error)
            failure = error
        }
        lastWakeAt = now
        lastWakeResult = Self.word(outcome)
        await afterTick(failure: failure, signInExpired: outcome == .signInExpired, at: now)
        if config.wake == .live, let measured = stack.probe.skew, now.timeIntervalSince(measured.measuredAt) <= 600 {
            if let since = skew.observe(failing: abs(measured.seconds) > 120, at: now) {
                log.error(email, "kello poikkeaa Gmailista \(Int(measured.seconds)) s: ei siivousta")
                await notifier.post(.persistentError(account: email, kind: "skew", since: since))
            }
        }
        heartbeat(units: stack.probe.totalUnits - unitsBefore, at: now)
        return outcome
    }

    private func recordWake(_ report: WakeReport, mode: FeatureMode, units: Int, at now: Date) {
        if let next = report.nextWakeAt { nextWakeAt = next } else if report.listingComplete { nextWakeAt = nil }
        let failed = report.failedThreadIDs.count + report.failedLabelIDs.count
        let shadow = mode != .live
        var woken = report.woken, cancelled = report.cancelled
        if shadow {
            // A shadow pass "wakes" the same due thread every minute: log each once per hour.
            shadowWakeSeen = shadowWakeSeen.filter { now.timeIntervalSince($0.value) < 3_600 }
            woken = woken.filter { shadowWakeSeen[$0] == nil }
            cancelled = cancelled.filter { shadowWakeSeen[$0] == nil }
            for id in woken + cancelled { shadowWakeSeen[id] = now }
        } else {
            rollToday(now)
            today.woken += woken.count
            today.cancelled += cancelled.count
            today.cleaned += report.deletedLabelIDs.count
        }
        guard !woken.isEmpty || !cancelled.isEmpty || !report.deletedLabelIDs.isEmpty || failed > 0 else { return }
        var line = "\(shadow ? "VARJO " : "")wake woken=\(woken.count) cancelled=\(cancelled.count) deleted=\(report.deletedLabelIDs.count)"
        if failed > 0 { line += " failed=\(failed)" }
        line += " next=\(report.nextWakeAt.map(DaemonLog.utcMinute) ?? "-") units=\(units)"
        if !woken.isEmpty { line += " threads=\((woken + cancelled).joined(separator: ","))" }
        log.log(failed > 0 ? .notice : .info, email, line)
    }

    // MARK: - Sync (§6.4)

    public func syncTick() async -> SyncOutcome {
        if phase.isNeedsLogin { await pollWhileNeedsLogin() }
        let (config, rules, problems) = await configStore.current()
        if problems != lastProblems {
            lastProblems = problems
            for problem in problems { log.error(email, "asetukset: \(problem) (käytössä viimeisin kelvollinen)") }
        }
        guard await prepare() else { return .skipped(phase.word) }
        await checkStack(config)
        guard phase.isActive, let stack, let engine else { return .skipped(phase.word) }
        let now = clock.now()
        await expiryCheck(config: config, stack: stack, engine: engine)
        guard phase.isActive else { return .skipped(phase.word) }
        await handleNoteRequests(stack: stack, engine: engine)
        guard config.sorting != .off else { return .skipped("off") }
        guard !safeMode.isActive else { return .skipped("safeMode") }
        await noteModeSince(config.sorting, now: now)
        if config.sorting == .live, labelsEnsuredGeneration != stackGeneration {
            let missing = await stack.sortDirectory.ensureExisting(rules.enabledLabels, visibility: .shown)
                .union(await stack.sortDirectory.ensureExisting([SeiseLabels.Sorting.classifiedMarker], visibility: .hidden))
            if missing.isEmpty {
                labelsEnsuredGeneration = stackGeneration
            } else {
                log.notice(email, "tunnisteita ei vahvistettu: \(missing.count), yritetään uudelleen")
            }
        }
        await budget.setUnitsPerMinute(config.sync.unitsPerMinute)
        // A label renamed in Gmail keeps its ID: re-list now and then, so names (L, rule labels) stay true.
        if config.sorting == .live, now.timeIntervalSince(sortLabelsListedAt ?? .distantPast) >= Self.labelRefreshInterval {
            try? await budget.spend(1)
            if (try? await stack.sortDirectory.refresh()) != nil { sortLabelsListedAt = now }
        }
        let unitsBefore = stack.probe.totalUnits
        let configStore = self.configStore
        let outcome = await engine.tick(SyncEnvironment(api: stack.sortAPI, directory: stack.sortDirectory,
                                                        mode: config.sorting, rules: rules, config: config,
                                                        currentMode: { await configStore.current().config.sorting }))
        let units = stack.probe.totalUnits - unitsBefore
        lastSyncAt = now
        lastSyncResult = outcome.result.word
        if phase == .backfillingSent, await engine.state.sentBackfill.phase == .done {
            phase = .running
            await onChange?()
        }
        rollToday(now)
        today.classified += outcome.counts.classified
        today.propagated += outcome.counts.propagated
        today.unmatched += outcome.counts.unmatched
        if outcome.counts.threads > 0 || outcome.counts.skipped > 0 {
            let c = outcome.counts
            log.info(email, "\(config.sorting == .shadow ? "VARJO " : "")sync threads=\(c.threads) classified=\(c.classified) "
                + "propagated=\(c.propagated) unmatched=\(c.unmatched) writes=\(c.writes) skipped=\(c.skipped) units=\(units)")
        }
        switch outcome.result {
        case .signInExpired:
            await enterNeedsLogin(.expired)
        case .stateWriteFailed:
            if let since = stateWrite.observe(failing: true, at: now) {
                await notifier.post(.persistentError(account: email, kind: "stateWrite", since: since))
            }
        case .offline, .rateLimited, .tokenEndpoint, .ok, .skipped, .cancelled, .failed:
            _ = stateWrite.observe(failing: false, at: now)
        }
        if outcome.result != .cancelled {
            await afterTick(failure: Self.error(for: outcome.result), signInExpired: false, at: now)
            var failing = outcome.counts.skipped > 0
            if case .failed = outcome.result { failing = true }
            if let since = failingTicks.observe(failing: failing, at: now) {
                await notifier.post(.persistentError(account: email, kind: "threads", since: since))
            }
        }
        heartbeat(units: units, at: now)
        return outcome
    }

    private static func error(for result: SyncResult) -> (any Error)? {
        switch result {
        case .offline: GmailError.offline
        case .rateLimited: GmailError.rateLimited
        case .tokenEndpoint: AuthError.badResponse
        default: nil
        }
    }

    /// The offline / rate-limit / token-endpoint throttles after either loop's tick.
    private func afterTick(failure: (any Error)?, signInExpired: Bool, at now: Date) async {
        if signInExpired {
            await enterNeedsLogin(.expired)
            return
        }
        let isOffline = (failure as? GmailError) == .offline
        let isRateLimited = failure.map(GmailFailure.isRateLimited) ?? false
        let isTokenEndpoint = (failure as? AuthError) == .badResponse
        if let since = offline.observe(failing: isOffline, at: now) {
            await notifier.post(.persistentError(account: email, kind: "offline", since: since))
        }
        if let since = rateLimited.observe(failing: isRateLimited, at: now) {
            await notifier.post(.persistentError(account: email, kind: "rateLimited", since: since))
        }
        if let since = tokenEndpoint.observe(failing: isTokenEndpoint, at: now) {
            await notifier.post(.persistentError(account: email, kind: "tokenEndpoint", since: since))
        }
    }

    private func noteModeSince(_ mode: FeatureMode, now: Date) async {
        guard let engine else { return }
        let state = await engine.state
        if mode == .shadow, state.shadowSince == nil {
            await engine.update { $0.shadowSince = now }
        } else if mode == .live, state.liveSince == nil {
            await engine.update { $0.liveSince = now }
        }
    }

    // MARK: - Start (§6.2)

    /// Brings the account to running: token checks, state load or bootstrap, the stack. Shared by both loops.
    /// False while not ready (needsLogin, stateError, or a transient failure retried next tick).
    private func prepare() async -> Bool {
        if phase.isActive, stack != nil, engine != nil { return true }
        if phase.isNeedsLogin { return false }
        if case .stateError = phase { return false }
        // The other loop is preparing (actor reentrancy): not ready yet; its next tick looks again.
        guard !isPreparing else { return false }
        isPreparing = true
        defer { isPreparing = false }
        return await doPrepare()
    }

    private func doPrepare() async -> Bool {
        let (config, _, _) = await configStore.current()
        let now = clock.now()
        let reader = FileTokenStore(fileURL: paths.token(email), readOnly: true)
        let stored: StoredToken
        do {
            guard let token = try reader.read() else {
                await enterNeedsLogin(.tokenMissing)
                return false
            }
            stored = token
        } catch {
            await enterNeedsLogin(.tokenUnreadable)
            return false
        }
        guard stored.clientID == oauth.clientID else {
            await enterNeedsLogin(.clientChanged)
            return false
        }
        let built = makeStack(email, config)
        var bootstrapped = false
        if engine == nil {
            let store = StateStore(url: paths.state(email), now: { [clock] in clock.now() })
            let state: AccountState
            switch store.load() {
            case .futureSchema(let schema):
                phase = .stateError("tilatiedoston skeema \(schema) on uudempi kuin tämä daemon")
                log.error(email, "tilatiedoston skeema \(schema) on tuntematon: tiliä ei käsitellä")
                await notifier.post(.persistentError(account: email, kind: "stateError", since: now))
                await onChange?()
                return false
            case .loaded(let s):
                state = s
            case .recovered(let s):
                log.notice(email, "tila palautettu varmuuskopiosta (.bak)")
                state = s
            case .missing:
                if !store.quarantined.isEmpty {
                    log.notice(email, "tilatiedosto oli lukukelvoton, siirretty sivuun: aloitetaan alusta")
                }
                do {
                    state = try await SyncEngine.bootstrap(account: email, api: built.sortAPI, now: now)
                } catch SyncEngine.BootstrapError.wrongAccount(let other) {
                    log.error(email, "tokeni kuuluu tilille \(other)")
                    await enterNeedsLogin(.wrongAccount)
                    return false
                } catch {
                    if WakeOutcome(error: error) == .signInExpired {
                        await enterNeedsLogin(.expired)
                    } else {
                        log.notice(email, "aloitus epäonnistui, yritetään uudelleen: \(SyncEngine.describe(error))")
                    }
                    return false
                }
                bootstrapped = true
            }
            let engine = SyncEngine(account: email, state: state, store: store, budget: budget, decisions: decisions,
                                    log: log, clock: clock, requests: paths.requests)
            if bootstrapped {
                await engine.save(force: true)
                log.notice(email, "tila luotu: vesileima \(state.watermark.historyId), lähetettyjen välimuisti rakennetaan")
            }
            self.engine = engine
        }
        installStack(built, config: config)
        guard let engine else { return false }
        let state = await engine.state
        // A persisted needsLogin for this very token: stay parked without spending an API call.
        if state.auth.status == .needsLogin, state.auth.fingerprint == stored.fingerprint.short {
            phase = .needsLogin(since: state.auth.since ?? now, reason: .expired)
            needsLoginFingerprint = stored.fingerprint
            log.notice(email, "kirjautuminen yhä vanhentunut: odotetaan uutta kirjautumista")
            await onChange?()
            return false
        }
        phase = state.sentBackfill.phase == .done ? .running : .backfillingSent
        log.info(email, "käynnissä (\(phase.word)), tokeni \(stored.fingerprint.short), herätys \(config.wake.rawValue), lajittelu \(config.sorting.rawValue)")
        if state.auth.status == .needsLogin {
            // A persisted needsLogin and another token: a login made while no runner watched (logout + login,
            // a disabled account, the daemon booted out). Resume for good, as the poll would have (§8.3).
            let since = state.auth.since ?? now
            let fp = stored.fingerprint.short
            let expiresAt = stored.expiresAt
            await engine.update { s in
                s.auth = AccountState.Auth(status: .ok, fingerprint: fp, expiresAt: expiresAt, noteThreadIDs: s.auth.noteThreadIDs)
            }
            await engine.save(force: true)
            log.notice(email, "uusi kirjautuminen: jatketaan (tauko \(DaemonEvent.duration(now.timeIntervalSince(since))))")
            await notifier.post(.resumed(account: email, after: now.timeIntervalSince(since)))
            resumedInPrepare = true
            await archiveNotes()
        }
        await onChange?()
        return true
    }

    private func installStack(_ built: AccountStack, config: DaemonConfig) {
        stack = built
        stackKey = StackKey(fingerprint: built.tokens.loadedFingerprint ?? built.tokens.currentFingerprint(),
                            wake: config.wake, sorting: config.sorting)
        stackGeneration += 1
        sortLabelsListedAt = clock.now()
    }

    // MARK: - Token and mode changes (D6, §8.3)

    /// Rebuilds the stack when the token file holds another token (re-login) or a mode changed.
    private func checkStack(_ config: DaemonConfig) async {
        guard let stack, let key = stackKey, phase.isActive else { return }
        let fileFingerprint = stack.tokens.currentFingerprint()
        let loaded = stack.tokens.loadedFingerprint ?? key.fingerprint
        if let fileFingerprint, fileFingerprint != loaded {
            // The same consent with another refresh token is no login (`debug invalidate-token`): rebuild so the
            // next call uses the file's token, but no `renewed`, no reset and no note archiving.
            if let file = try? FileTokenStore(fileURL: paths.token(email), readOnly: true).read(),
               let current = stack.tokens.loadedToken, file.consentedAt == current.consentedAt, file.clientID == current.clientID {
                log.notice(email, "tokenitiedosto vaihtui ilman uutta kirjautumista (tokeni \(file.fingerprint.short)): "
                    + "otetaan käyttöön")
                installStack(makeStack(email, config), config: config)
                return
            }
            await tokenReplaced(config: config, resuming: false)
            return
        }
        if key.wake != config.wake || key.sorting != config.sorting {
            log.notice(email, "tila vaihtui: herätys \(config.wake.rawValue), lajittelu \(config.sorting.rawValue)")
            installStack(makeStack(email, config), config: config)
        }
    }

    /// A new login: rebuild, reset the expiry bookkeeping, archive the notes, and tell.
    private func tokenReplaced(config: DaemonConfig, resuming: Bool) async {
        let now = clock.now()
        let reader = FileTokenStore(fileURL: paths.token(email), readOnly: true)
        guard let stored = try? reader.read() else { return }
        guard stored.clientID == oauth.clientID else {
            await enterNeedsLogin(.clientChanged)
            return
        }
        let since: Date? = if case .needsLogin(let s, _) = phase { s } else { nil }
        installStack(makeStack(email, config), config: config)
        if let engine {
            let fp = stored.fingerprint.short
            let expiresAt = stored.expiresAt
            await engine.update { s in
                s.auth = AccountState.Auth(status: .ok, fingerprint: fp, expiresAt: expiresAt,
                                           noteThreadIDs: s.auth.noteThreadIDs)
            }
            await engine.save(force: true)
            phase = await engine.state.sentBackfill.phase == .done ? .running : .backfillingSent
        } else {
            phase = .starting
        }
        needsLoginFingerprint = nil
        notifiedWithoutState = false
        if resuming, let since {
            log.notice(email, "uusi kirjautuminen: jatketaan (tauko \(DaemonEvent.duration(now.timeIntervalSince(since))))")
            await notifier.post(.resumed(account: email, after: now.timeIntervalSince(since)))
        } else {
            log.notice(email, "kirjautuminen uusittu, tokeni \(stored.fingerprint.short)")
            await notifier.post(.renewed(account: email, expiresAt: stored.expiresAt))
        }
        if phase.isActive { await archiveNotes() }
        await onChange?()
    }

    /// Polls the token file every 30 s while needsLogin (no API calls) and sends the daily reminder.
    private func pollWhileNeedsLogin() async {
        guard case .needsLogin(let since, let reason) = phase, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        let now = clock.now()
        let current = FileTokenStore(fileURL: paths.token(email), readOnly: true).currentFingerprint()
        if let current, current != needsLoginFingerprint {
            let (config, _, _) = await configStore.current()
            if engine == nil || stack == nil {
                // Never got running (missing/unreadable/foreign token): start over with the new file.
                phase = .starting
                needsLoginFingerprint = nil
                resumedInPrepare = false
                if await prepare(), !resumedInPrepare {
                    await notifier.post(.resumed(account: email, after: now.timeIntervalSince(since)))
                    await archiveNotes()
                }
                resumedInPrepare = false
                return
            }
            await tokenReplaced(config: config, resuming: true)
            return
        }
        guard reason == .expired || engine != nil, let engine else { return }
        let (config, _, _) = await configStore.current()
        let last = await engine.state.auth.lastNotifiedAt
        if ExpiryPlan.reminderDue(now: now, lastNotifiedAt: last, hour: config.notify.reminderHour) {
            await engine.update { $0.auth.lastNotifiedAt = now }
            await engine.save(force: true)
            await notifier.post(.needsLogin(account: email, since: since, reminder: true))
        }
    }

    /// `invalid_grant` / not signed in / no usable token (§8.3): park, keep W and everything, notify once.
    private func enterNeedsLogin(_ reason: LoginReason) async {
        let now = clock.now()
        let fingerprint = FileTokenStore(fileURL: paths.token(email), readOnly: true).currentFingerprint()
        let since: Date
        if case .needsLogin(let s, _) = phase { since = s } else { since = now }
        phase = .needsLogin(since: since, reason: reason)
        needsLoginFingerprint = fingerprint
        log.error(email, "kirjautuminen ei kelpaa (\(reason.rawValue)): odotetaan uutta kirjautumista")
        var notify = false
        if let engine {
            let auth = await engine.state.auth
            let already = auth.status == .needsLogin && (fingerprint == nil || auth.fingerprint == fingerprint?.short)
            let start = already ? (auth.since ?? since) : since
            phase = .needsLogin(since: start, reason: reason)
            await engine.update { s in
                s.auth.status = .needsLogin
                s.auth.since = start
                if let fingerprint { s.auth.fingerprint = fingerprint.short }
                if !already { s.auth.lastNotifiedAt = now }
            }
            await engine.save(force: true)
            notify = !already
        } else if !notifiedWithoutState {
            notifiedWithoutState = true
            notify = true
        }
        if notify, case .needsLogin(let start, _) = phase {
            await notifier.post(.needsLogin(account: email, since: start, reminder: false))
        }
        await onChange?()
    }

    // MARK: - Expiry notes (§8.3)

    /// T−24 h / T−3 h: `warned` is saved before the note is inserted, so a crash can lose a note but never
    /// duplicate one. Several due at once (a late start) send one note.
    private func expiryCheck(config: DaemonConfig, stack: AccountStack, engine: SyncEngine) async {
        guard let token = stack.tokens.loadedToken else { return }
        let now = clock.now()
        let fp = token.fingerprint.short
        let expiresAt = token.expiresAt
        var auth = await engine.state.auth
        if auth.fingerprint != fp || auth.expiresAt != expiresAt || auth.status != .ok {
            // A new consent (another expiry) starts the warnings over; a rotated refresh token is the same login.
            if auth.expiresAt != expiresAt { auth.warned = [] }
            // Running with a usable token: a stored needsLogin is stale (never park the next start on it).
            auth.status = .ok
            auth.since = nil
            auth.fingerprint = fp
            auth.expiresAt = expiresAt
            let updated = auth
            await engine.update { $0.auth = updated }
            await engine.save()
        }
        let due = ExpiryPlan.dueWarnings(now: now, expiresAt: expiresAt, warnHours: config.notify.warnHours, warned: auth.warned)
        guard let hours = due.min() else { return }
        await engine.update { $0.auth.warned = Array(Set($0.auth.warned + due)).sorted(by: >) }
        guard await engine.save(force: true) else { return }
        if config.notify.inboxNote {
            do {
                let raw = InboxNote.raw(account: email, expiresAt: expiresAt, now: now)
                let id = try await stack.noteAPI.insertMessage(raw: raw, labelIDs: InboxNote.labelIDs)
                await engine.update { $0.auth.noteThreadIDs.append(id) }
                await engine.save(force: true)
                log.notice(email, "muistutus Saapuneisiin: kirjautuminen vanhenee \(DaemonLog.utcMinute(expiresAt)) (\(hours) h)")
            } catch {
                log.error(email, "muistutusviestin lisäys epäonnistui: \(SyncEngine.describe(error))")
            }
        }
        await notifier.post(.expiresSoon(account: email, expiresAt: expiresAt, hours: hours))
    }

    /// Archives the stored expiry notes (`threads.modify remove INBOX`); failures stay for the next login.
    private func archiveNotes() async {
        guard let engine, let stack else { return }
        let ids = await engine.state.auth.noteThreadIDs
        guard !ids.isEmpty else { return }
        var remaining: [String] = []
        for id in ids {
            do {
                try await stack.noteAPI.modify(threadID: id, add: [], remove: [GmailLabel.inbox])
            } catch let error where GmailFailure.isNotFound(error) {
                continue
            } catch {
                log.notice(email, "muistutuksen \(id) arkistointi epäonnistui: \(SyncEngine.describe(error))")
                remaining.append(id)
            }
        }
        let left = remaining
        await engine.update { $0.auth.noteThreadIDs = left }
        await engine.save(force: true)
    }

    /// `debug note-now` (the CLI holding the lock): inserts the expiry note at once (no `warned` bookkeeping).
    public func insertNoteNow() async throws -> String {
        guard await prepare(), let stack, let engine else { throw AuthError.notSignedIn }
        return try await insertNote(stack: stack, engine: engine)
    }

    private func insertNote(stack: AccountStack, engine: SyncEngine) async throws -> String {
        guard let token = stack.tokens.loadedToken else { throw AuthError.notSignedIn }
        let raw = InboxNote.raw(account: email, expiresAt: token.expiresAt, now: clock.now())
        let id = try await stack.noteAPI.insertMessage(raw: raw, labelIDs: InboxNote.labelIDs)
        await engine.update { $0.auth.noteThreadIDs.append(id) }
        await engine.save(force: true)
        return id
    }

    /// `debug note-now` while the daemon runs (`NoteRequest`): one note for any number of pending files,
    /// which are deleted once it is in. A failure keeps them for the next tick.
    private func handleNoteRequests(stack: AccountStack, engine: SyncEngine) async {
        let files = NoteRequest.pending(account: email, in: paths.requests)
        guard !files.isEmpty else { return }
        do {
            let id = try await insertNote(stack: stack, engine: engine)
            for file in files { try? FileManager.default.removeItem(at: file) }
            log.notice(email, "muistutus Saapuneisiin pyynnöstä (debug note-now): \(id)")
        } catch {
            log.error(email, "muistutusviestin lisäys pyynnöstä epäonnistui: \(SyncEngine.describe(error))")
        }
    }

    /// Saves the state now (`once` before it exits; `run` saves on cancellation by itself).
    public func flush() async {
        if let engine { await engine.save(force: true) }
    }

    // MARK: - Status

    public func status() async -> AccountStatus {
        // The awaits come first: everything below reads the actor's fields without a suspension point, so
        // the snapshot is consistent (a phase change during an await never pairs an old phase with a new action).
        let state = await engine?.state
        let cap = await configStore.current().config.sentBackfill.maxMessages
        let now = clock.now()
        rollToday(now)
        var s = AccountStatus(email: email, phase: phase.word, today: today)
        s.lastWakeAt = lastWakeAt
        s.lastWakeResult = lastWakeResult
        s.nextWakeAt = nextWakeAt
        s.lastSyncAt = lastSyncAt
        s.lastSyncResult = lastSyncResult
        if let stack {
            s.expiresAt = stack.tokens.loadedToken?.expiresAt
            s.skewSeconds = stack.probe.skew.map { ($0.seconds * 10).rounded() / 10 }
            s.unitsLastMinute = stack.probe.unitsLastMinute
        }
        if let state {
            s.watermarkAgeSeconds = Int(now.timeIntervalSince(state.watermark.advancedAt))
            s.sentBackfill = state.sentBackfill.phase.rawValue
            if state.sentBackfill.phase != .done {
                s.sentBackfillProgress = "\(state.sentBackfill.fetched)/\(cap)"
            }
            s.scan = state.scan.map { "\($0.kind.rawValue) \($0.stage.rawValue) \($0.threads)" }
            s.expiresAt = s.expiresAt ?? state.auth.expiresAt
            s.shadowSince = state.shadowSince
            s.liveSince = state.liveSince
        }
        switch phase {
        case .needsLogin(_, let reason):
            s.reason = reason.rawValue
            s.attention = "KIRJAUDU UUDELLEEN"
            s.action = "Kirjaudu uudelleen: mak8r-daemon login \(email)"
        case .stateError(let text):
            s.attention = "tilatiedosto: \(text)"
        default:
            if offline.since.map({ now.timeIntervalSince($0) >= 6 * 3_600 }) == true {
                s.attention = "ei verkkoyhteyttä"
            } else if lastSyncResult == SyncResult.stateWriteFailed.word {
                s.attention = "tilaa ei voi tallentaa, lajittelu pysäytetty"
            } else if let expiresAt = s.expiresAt, expiresAt.timeIntervalSince(now) < 24 * 3_600 {
                s.attention = "kirjautuminen vanhenee pian"
                s.action = "Kirjaudu uudelleen: mak8r-daemon login \(email)"
            }
        }
        return s
    }

    // MARK: - Helpers

    private func rollToday(_ now: Date) {
        let start = DaemonSchedule.dayStart(now)
        if todayStart != start {
            todayStart = start
            today = AccountStatus.Today()
        }
    }

    /// An hourly summary line, so a quiet log still shows the daemon is alive.
    private func heartbeat(units: Int, at now: Date) {
        hourUnits += units
        guard let last = lastHeartbeat else {
            lastHeartbeat = now
            return
        }
        guard now.timeIntervalSince(last) >= 3_600 else { return }
        log.info(email, "tunti: \(phase.word) units=\(hourUnits) woken=\(today.woken) classified=\(today.classified) "
            + "propagated=\(today.propagated) unmatched=\(today.unmatched)")
        lastHeartbeat = now
        hourUnits = 0
    }

    private static func word(_ outcome: WakeOutcome) -> String {
        switch outcome {
        case .completed: "ok"
        case .skipped: "skipped"
        case .paused: "paused"
        case .offline: "offline"
        case .rateLimited: "rateLimited"
        case .signInExpired: "signInExpired"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }
}
