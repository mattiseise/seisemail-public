import DaemonCore
import Foundation
import MailCore

/// `mak8r-daemon run`, the LaunchAgent's entry point (design §6.1, §6.8).
enum RunCommand {
    static func run(paths: DaemonPaths) async -> Int32 {
        // 1. Signals: ignored at the C level and handled by dispatch sources from this moment on; a TERM during
        //    startup is kept by the latch and cancels the root task as soon as it exists (exit 0, never SIGKILL).
        Signals.ignoreAll()
        let termination = TerminationLatch()
        let sources = Signals.onTermination { termination.request() }
        defer { withExtendedLifetime(sources) {} }

        // 2. Folders (0700), logs; launchd's crash output is truncated past 1 MiB.
        do {
            try paths.createDirectories()
        } catch {
            Output.error("mak8r-daemon: kansioita ei voi luoda: \(error)")
            return DaemonExitCode.unavailable.rawValue
        }
        RotatingFile.truncate(paths.stdoutLog, ifLargerThan: 1 << 20)
        RotatingFile.truncate(paths.stderrLog, ifLargerThan: 1 << 20)
        let environment = ProcessInfo.processInfo.environment
        let log = DaemonLog(sink: RotatingFile(url: paths.daemonLog, maxBytes: 5 << 20),
                            debug: environment["MAK8R_DAEMON_DEBUG"] == "1")
        let decisions = DecisionLog(sink: RotatingFile(url: paths.decisions, maxBytes: 10 << 20))

        // 3. Single instance: busy → 75, so launchd (KeepAlive SuccessfulExit=false) tries again later.
        let lock: InstanceLock
        do {
            lock = try InstanceLock(paths.lock)
        } catch .busy {
            log.notice(nil, "toinen daemon pitää lukkoa: poistutaan (\(InstanceLock.busyExitCode))")
            return InstanceLock.busyExitCode
        } catch {
            log.error(nil, "lukkoa ei voi avata: \(error)")
            return DaemonExitCode.unavailable.rawValue
        }

        // 4. Crash-loop guard (D16): only unclean starts count; the previous graceful stop left a marker.
        let clock = SystemDaemonClock()
        let startedAt = clock.now()
        let guardFile = StartGuard(url: paths.starts)
        let start = guardFile.recordStart(at: startedAt)
        let configStore = ConfigStore(paths: paths)
        let notifier = NotifierHub(log: log, sinks: [CommandNotifier(configStore: configStore, log: log)])
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        log.notice(nil, "käynnistyy: pid \(getpid()), käännös \(build), OAuth-asiakas "
            + (OAuthConfig.fromBundle() == nil ? "puuttuu" : "löytyi") + ", "
            + (start.clean ? "edellinen pysäytys hallittu" : "käynnistyksiä ilman hallittua pysäytystä 10 min aikana \(start.starts)"))

        // 5–6. The supervisor waits for an OAuth client by itself (status `error`), never exit-looping.
        let supervisor = Supervisor(paths: paths, oauth: { OAuthConfig.fromBundle() }, configStore: configStore,
                                    notifier: notifier, log: log, decisions: decisions, clock: clock,
                                    safeMode: start.safeMode, startedAt: startedAt, build: build)
        let root = Task {
            if start.safeMode { await notifier.post(.safeMode(starts: start.starts)) }   // a slow hook ends on TERM
            guard !Task.isCancelled else { return }
            await supervisor.run()
        }
        termination.attach(root)
        await root.value
        // 6.8: the state is saved and status.json says stopped. The marker is the last write, still under the
        // lock, so a crash anywhere before it leaves the next start counted.
        guardFile.recordCleanShutdown(at: clock.now())
        log.notice(nil, "pysäytetty")
        lock.release()
        return DaemonExitCode.ok.rawValue
    }
}
