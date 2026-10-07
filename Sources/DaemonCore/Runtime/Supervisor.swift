import Darwin
import Foundation
import MailCore

/// Runs one `AccountRunner` per token file (minus `disabledAccounts`) and writes `status.json`
/// (design §6.1, §9.4). Every 60 s it rediscovers the accounts: a new token file starts a runner, a
/// removed one (logout) or a disabled account stops it. Runners start 2 s apart.
public actor Supervisor {
    public typealias StackFactory = @Sendable (String, OAuthConfig, DaemonConfig) -> AccountStack

    private let paths: DaemonPaths
    private let oauth: @Sendable () -> OAuthConfig?
    private let configStore: ConfigStore
    private let notifier: any DaemonNotifier
    private let log: DaemonLog
    private let decisions: DecisionLog
    private let clock: any DaemonClock
    private let safeMode: SafeMode
    private let startedAt: Date
    private let pid: Int32
    private let build: String
    private let stagger: TimeInterval
    private let interval: TimeInterval
    private let makeStack: StackFactory

    private var runners: [String: (runner: AccountRunner, task: Task<Void, Never>)] = [:]
    private var order: [String] = []
    private var oauthMissing = false
    private var statusSequence = 0
    private var lastWrittenSequence = 0
    /// Tests only: runs after a status write took its sequence number, before it gathers the snapshot.
    private var beforeStatusSnapshot: (@Sendable (Int) async -> Void)?

    func setBeforeStatusSnapshot(_ hook: (@Sendable (Int) async -> Void)?) {
        beforeStatusSnapshot = hook
    }

    /// `oauth` is re-read every pass while it is missing (status `error: OAuth-asiakas puuttuu`, no exit
    /// loop). `makeStack` defaults to `AccountStack.make`, logging shadow writes at debug level.
    public init(paths: DaemonPaths, oauth: @escaping @Sendable () -> OAuthConfig?, configStore: ConfigStore,
                notifier: any DaemonNotifier, log: DaemonLog, decisions: DecisionLog, clock: any DaemonClock,
                safeMode: Bool = false, startedAt: Date, pid: Int32 = getpid(), build: String = "0",
                stagger: TimeInterval = 2, interval: TimeInterval = 60, makeStack: StackFactory? = nil) {
        self.paths = paths
        self.oauth = oauth
        self.configStore = configStore
        self.notifier = notifier
        self.log = log
        self.decisions = decisions
        self.clock = clock
        self.safeMode = SafeMode(active: safeMode, since: startedAt)
        self.startedAt = startedAt
        self.pid = pid
        self.build = build
        self.stagger = stagger
        self.interval = interval
        self.makeStack = makeStack ?? { email, oauth, config in
            AccountStack.make(email: email, oauth: oauth, paths: paths, config: config, log: log) { write in
                log.debug(email, "VARJO \(write.summary)")
            }
        }
    }

    /// Until cancelled: reconcile and write the status every `interval`. On cancellation the runners are
    /// cancelled and awaited (each saves its state) and the status says `stopped`. Safe mode ends at the first
    /// pass after `SafeMode.stableRun` of running (D16); sorting then resumes in its configured mode.
    public func run() async {
        if let clearsAt = safeMode.snapshot.clearsAt {
            log.error(nil, "turvatila: lajittelu pois päältä, kunnes daemon on ollut käynnissä 30 min ilman "
                + "uudelleenkäynnistystä (\(DaemonLog.utcMinute(clearsAt)))")
        }
        while !Task.isCancelled {
            if safeMode.clearIfStable(now: clock.now()) {
                log.notice(nil, "turvatila päättyi: 30 min vakaata ajoa, lajittelu jatkuu asetusten mukaan")
            }
            await reconcile()
            await writeStatus()
            if (try? await clock.sleep(until: clock.now().addingTimeInterval(interval))) == nil { break }
        }
        await stopAll()
        await writeStatus(stopped: true)
    }

    /// One discovery pass: start runners for new token files, stop those whose file or account is gone.
    public func reconcile() async {
        let (config, _, _) = await configStore.current()
        guard let oauth = oauth() else {
            if !oauthMissing {
                oauthMissing = true
                log.error(nil, "OAuth-asiakas puuttuu: aja make daemon-install uudelleen")
            }
            return
        }
        if oauthMissing {
            oauthMissing = false
            log.notice(nil, "OAuth-asiakas löytyi")
        }
        let wanted = paths.tokenAccounts().filter { !config.isDisabled($0) }
        for email in order where !wanted.contains(email) {
            await stop(email)
        }
        var first = true
        for email in wanted where runners[email] == nil {
            if !first, stagger > 0 {
                if (try? await clock.sleep(until: clock.now().addingTimeInterval(stagger))) == nil { return }
            }
            first = false
            start(email, oauth: oauth)
        }
        if wanted.isEmpty, order.isEmpty { log.debug(nil, "ei tilejä") }
    }

    /// Accounts with a running runner, in start order.
    public var accounts: [String] { order }

    public func runner(for email: String) -> AccountRunner? {
        runners[email.lowercased()]?.runner
    }

    private func start(_ email: String, oauth: OAuthConfig) {
        let factory = makeStack
        let runner = AccountRunner(
            email: email, paths: paths, oauth: oauth, configStore: configStore, notifier: notifier, log: log,
            decisions: decisions, clock: clock, makeStack: { email, config in factory(email, oauth, config) },
            safeMode: safeMode, onChange: { [weak self] in await self?.writeStatus() }
        )
        let task = Task { await runner.run() }
        runners[email] = (runner, task)
        order.append(email)
        log.notice(email, "tili mukaan")
    }

    private func stop(_ email: String) async {
        guard let entry = runners.removeValue(forKey: email) else { return }
        order.removeAll { $0 == email }
        entry.task.cancel()
        await entry.task.value
        log.notice(email, "tili pois (tokeni poistettu tai tili poistettu käytöstä)")
    }

    public func stopAll() async {
        for email in order { await stop(email) }
    }

    public func status(stopped: Bool = false) async -> DaemonStatus {
        let (config, _, problems) = await configStore.current()
        var accounts: [AccountStatus] = []
        for email in order {
            if let runner = runners[email]?.runner { accounts.append(await runner.status()) }
        }
        let now = clock.now()
        let safe = safeMode.snapshot
        return DaemonStatus(pid: pid, build: build, state: stopped ? "stopped" : "running", startedAt: startedAt,
                            writtenAt: now, safeMode: safe.active, safeModeUntil: safe.clearsAt,
                            safeModeClearedAt: safe.clearedAt,
                            modes: .init(wake: config.wake, sorting: safe.active ? .off : config.sorting),
                            configProblems: problems, error: oauthMissing ? "OAuth-asiakas puuttuu" : nil,
                            accounts: accounts)
    }

    public func writeStatus(stopped: Bool = false) async {
        // Writes interleave at the awaits (a phase change triggers one while the minute's write gathers):
        // a snapshot started before the last written one is older and must not overwrite it.
        statusSequence += 1
        let sequence = statusSequence
        if let beforeStatusSnapshot { await beforeStatusSnapshot(sequence) }
        let snapshot = await status(stopped: stopped)
        guard sequence > lastWrittenSequence else { return }
        lastWrittenSequence = sequence
        do {
            try StatusFile.write(snapshot, to: paths.status)
        } catch {
            log.error(nil, "status.json: \(error)")
        }
    }
}
