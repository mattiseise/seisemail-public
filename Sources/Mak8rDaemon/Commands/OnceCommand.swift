import DaemonCore
import Foundation
import MailCore

/// The daemon's stack in the foreground (`once`, `debug note-now` while the daemon is stopped): the same
/// runner, files and logs as `run`, with log lines echoed to stdout.
struct Foreground {
    let paths: DaemonPaths
    let oauth: OAuthConfig
    let log: DaemonLog
    let decisions: DecisionLog
    let configStore: ConfigStore
    let notifier: NotifierHub

    init(paths: DaemonPaths, oauth: OAuthConfig, echo: Bool) {
        self.paths = paths
        self.oauth = oauth
        try? paths.createDirectories()
        let file = RotatingFile(url: paths.daemonLog, maxBytes: 5 << 20)
        let sink: any LogSink = echo ? TeeSink([file, StdoutSink()]) : file
        log = DaemonLog(sink: sink, debug: ProcessInfo.processInfo.environment["MAK8R_DAEMON_DEBUG"] == "1")
        decisions = DecisionLog(sink: RotatingFile(url: paths.decisions, maxBytes: 10 << 20))
        configStore = ConfigStore(paths: paths)
        notifier = NotifierHub(log: log)
    }

    func runner(_ email: String) -> AccountRunner {
        let (paths, oauth, log) = (paths, oauth, log)
        return AccountRunner(
            email: email, paths: paths, oauth: oauth, configStore: configStore, notifier: notifier, log: log,
            decisions: decisions, clock: SystemDaemonClock(),
            makeStack: { account, config in
                AccountStack.make(email: account, oauth: oauth, paths: paths, config: config, log: log) { write in
                    log.info(account, "VARJO \(write.summary)")
                }
            }
        )
    }
}

/// `once [--account a] [--wake|--sync]` (design §15): one tick in the foreground, in the current modes.
/// Refuses (75) while the daemon holds the lock: two writers of one state file are never allowed.
enum OnceCommand {
    static func run(account: String?, scope: DaemonCommand.OnceScope, paths: DaemonPaths) async -> Int32 {
        let lock: InstanceLock
        do {
            lock = try InstanceLock(paths.lock)
        } catch .busy {
            Output.error(Text.lockHeldOnce)
            return InstanceLock.busyExitCode
        } catch {
            Output.error("Lukkoa ei voi avata: \(error)")
            return DaemonExitCode.unavailable.rawValue
        }
        defer { lock.release() }
        let accounts: [String]
        do {
            accounts = account == nil && paths.tokenAccounts().count > 1
                ? paths.tokenAccounts()
                : [try AccountChoice.resolve(account, paths: paths)]
        } catch {
            return AccountCommands.usage(error)
        }
        guard let oauth = OAuthConfig.fromBundle() else { return AccountCommands.oauthMissing() }
        let foreground = Foreground(paths: paths, oauth: oauth, echo: true)
        var code = DaemonExitCode.ok
        for email in accounts {
            let runner = foreground.runner(email)
            if scope != .sync {
                Output.line("\(email): herätys: \(StatusReport.wakeText(await runner.wakeTick()))")
            }
            if scope != .wake {
                Output.line("\(email): lajittelu: \(StatusReport.syncText(await runner.syncTick()))")
            }
            await runner.flush()
            let status = await runner.status()
            for line in StatusReport.accountLines(status, now: Date()) { Output.line(line) }
            if status.attention != nil { code = .attention }
        }
        return code.rawValue
    }
}

/// Writes every line to each sink.
struct TeeSink: LogSink {
    let sinks: [any LogSink]

    init(_ sinks: [any LogSink]) {
        self.sinks = sinks
    }

    func write(_ line: String) {
        for sink in sinks { sink.write(line) }
    }
}

struct StdoutSink: LogSink {
    func write(_ line: String) { Output.line(line) }
}
