import Foundation
import Synchronization
import Testing
@testable import DaemonCore
@testable import MailCore

/// D14/D16 and §9.4: the supervisor discovers token files, writes `status.json` (the contract for `status` and
/// local monitors), and honours `disabledAccounts` and safe mode.
@Suite struct SupervisorTests {
    let env: DaemonEnv

    init() throws {
        env = try DaemonEnv()
        try env.setConfig(wake: .live, sorting: .shadow)
    }

    func status() -> [String: Any]? { jsonObject(env.paths.status) }

    func accounts() -> [[String: Any]] { status()?["accounts"] as? [[String: Any]] ?? [] }

    func emails() -> [String] { accounts().compactMap { $0["email"] as? String } }

    func start(safeMode: Bool = false) -> Task<Void, Never> {
        let supervisor = env.supervisor(safeMode: safeMode)
        return Task { await supervisor.run() }
    }

    /// 7230a08: writes interleave at their awaits; a snapshot begun before the last written one never overwrites it.
    @Test func anOlderStatusSnapshotNeverOverwritesANewerOne() async throws {
        let supervisor = env.supervisor()
        let entered = Mutex(false), release = Mutex(false)
        await supervisor.setBeforeStatusSnapshot { sequence in
            guard sequence == 1 else { return }
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
        }
        let older = Task { await supervisor.writeStatus() }               // "running", held before its snapshot
        #expect(await eventually { entered.withLock { $0 } })
        await supervisor.writeStatus(stopped: true)                         // newer: written
        #expect(status()?["state"] as? String == "stopped")
        release.withLock { $0 = true }
        await older.value
        #expect(status()?["state"] as? String == "stopped")
    }

    @Test func statusFileContract() async throws {
        try env.writeToken()
        try env.seedState(watermark: "1000")
        let task = start()
        #expect(await eventually { (jsonObject(env.paths.status)?["accounts"] as? [[String: Any]])?.count == 1 })
        let s = try #require(status())
        #expect(s["schema"] as? Int == 1)
        #expect(s["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(s["build"] as? String == "92")
        #expect(s["startedAt"] is String)
        #expect(s["writtenAt"] is String)
        #expect(s["safeMode"] as? Bool == false)
        #expect(s["modes"] as? [String: String] == ["wake": "live", "sorting": "shadow"])
        #expect(s["configProblems"] as? [String] == [])
        let account = try #require(accounts().first)
        #expect(account["email"] as? String == env.email)
        #expect(account["phase"] is String)
        // Always present; the other §9.4 fields (attention, lastWakeAt, …, action) may be null or absent until known.
        for key in ["expiresAt", "sentBackfill", "unitsLastMinute", "today"] {
            #expect(account.keys.contains(key), "accounts[].\(key)")
        }
        // §9.4 plus `reason` (why needsLogin), `sentBackfillProgress` ("x/y" for §22 step 10) and `scan`.
        let known: Set<String> = ["email", "phase", "expiresAt", "attention", "lastWakeAt", "lastWakeResult", "nextWakeAt",
                                  "lastSyncAt", "lastSyncResult", "watermarkAgeSeconds", "sentBackfill", "skewSeconds",
                                  "unitsLastMinute", "today", "action", "reason", "sentBackfillProgress", "scan",
                                  "shadowSince", "liveSince"]
        #expect(Set(account.keys).isSubset(of: known), "\(Set(account.keys).subtracting(known))")
        let today = try #require(account["today"] as? [String: Any])
        #expect(Set(today.keys) == ["woken", "cancelled", "cleaned", "classified", "propagated", "unmatched"])
        #expect(posixMode(env.paths.status) == 0o600)
        task.cancel()
        await task.value
    }

    @Test func statusCarriesTheSortingStartsFromTheState() async throws {
        try env.writeToken()
        try env.seedState(watermark: "1000")                                // shadowSince a day ago, liveSince null
        let seeded = env.clock.now().addingTimeInterval(-86_400)
        let task = start()
        #expect(await drive(env.clock, sleepers: 3) { (accounts().first?["shadowSince"] as? String) != nil })
        let account = try #require(accounts().first)
        #expect((account["shadowSince"] as? String).flatMap { parseISO($0) } == seeded)
        #expect(account["liveSince"] is NSNull)
        task.cancel()
        await task.value
    }

    @Test func statusNamesTheLoginActionInNeedsLogin() async throws {
        try env.writeToken()
        try env.seedState(watermark: "1000")
        env.fake.update { $0.failAll = AuthError.invalidGrant }
        let task = start()
        #expect(await drive(env.clock, sleepers: 1) {
            ((jsonObject(env.paths.status)?["accounts"] as? [[String: Any]])?.first?["action"] as? String)?
                .contains("mak8r-daemon login") == true
        })
        let account = try #require(accounts().first)
        #expect(account["phase"] as? String == "needsLogin")
        #expect((account["action"] as? String)?.contains(env.email) == true)
        task.cancel()
        await task.value
    }

    @Test func tokenFileAddedOrRemovedStartsOrStopsARunner() async throws {
        let task = start()
        #expect(await eventually { jsonObject(env.paths.status) != nil })
        #expect(emails().isEmpty)
        try env.writeToken()
        #expect(await drive(env.clock, sleepers: 1) {
            ((jsonObject(env.paths.status)?["accounts"] as? [[String: Any]]) ?? []).count == 1
        })
        #expect(emails() == [env.email])
        try FileTokenStore.delete(env.paths.token(env.email))
        #expect(await drive(env.clock, sleepers: 1) {
            ((jsonObject(env.paths.status)?["accounts"] as? [[String: Any]]) ?? []).isEmpty
        })
        let attempts = env.fake.attempts
        for _ in 0..<3 {
            env.clock.advance(by: 60)
            for _ in 0..<200 { await Task.yield() }                       // give a stopped runner time to misbehave
        }
        #expect(env.fake.attempts == attempts)
        task.cancel()
        await task.value
    }

    @Test func disabledAccountsAreNotStarted() async throws {
        try env.setConfig(wake: .live, sorting: .shadow) { $0.disabledAccounts = [env.email] }
        try env.writeToken()
        try env.seedState(watermark: "1000")
        let task = start()
        #expect(await eventually { jsonObject(env.paths.status) != nil })
        for _ in 0..<3 {
            env.clock.advance(by: 60)
            for _ in 0..<200 { await Task.yield() }
        }
        #expect(env.fake.attempts == 0)
        #expect(!emails().contains(env.email) || accounts().first?["phase"] as? String != "running")
        task.cancel()
        await task.value
    }

    @Test func safeModeClearsItselfAfterThirtyMinutesOfStableRunning() async throws {
        try env.writeToken()
        try env.seedState(watermark: "1000")
        let startedAt = env.clock.now()
        let task = start(safeMode: true)
        #expect(await eventually { status()?["safeMode"] as? Bool == true })
        let until = try #require((status()?["safeModeUntil"] as? String).flatMap { parseISO($0) })
        #expect(until == startedAt.addingTimeInterval(1_800))
        #expect(await drive(env.clock, sleepers: 3, steps: 200) { env.clock.now() >= startedAt.addingTimeInterval(1_700) })
        #expect(status()?["safeMode"] as? Bool == true)
        #expect(env.fake.historyStarts.isEmpty)                            // still no sorting
        #expect(await drive(env.clock, sleepers: 3, steps: 30) { status()?["safeMode"] as? Bool == false })
        let s = try #require(status())
        #expect((s["modes"] as? [String: String])?["sorting"] == "shadow")
        #expect(s["safeModeUntil"] == nil)
        let cleared = try #require((s["safeModeClearedAt"] as? String).flatMap { parseISO($0) })
        #expect(cleared >= startedAt.addingTimeInterval(1_800))
        #expect(cleared <= startedAt.addingTimeInterval(1_860))           // at the supervisor's next minute
        #expect(await drive(env.clock, sleepers: 3, steps: 12) { !env.fake.historyStarts.isEmpty })   // sorting resumed
        #expect(env.logText.contains("turvatila päättyi"))
        task.cancel()
        await task.value
    }

    @Test func safeModeForcesSortingOffButKeepsWakes() async throws {
        try env.writeToken()
        try env.seedState(watermark: "1000")
        env.fake.labels.addSnoozedThread("snoozed", wake: "20261005T0800Z")
        let task = start(safeMode: true)
        #expect(await drive(env.clock, sleepers: 1) { env.fake.modifies(of: "snoozed").count == 1 })
        let past = env.clock.now().addingTimeInterval(130)                 // at least two sync deadlines (mm:20)
        #expect(await drive(env.clock, sleepers: 1, steps: 24) { env.clock.now() >= past })
        #expect(env.fake.historyStarts.isEmpty)
        let s = try #require(status())
        #expect(s["safeMode"] as? Bool == true)
        #expect((s["modes"] as? [String: String])?["sorting"] == "off")
        #expect((s["modes"] as? [String: String])?["wake"] == "live")
        task.cancel()
        await task.value
    }

    @Test func invalidRulesShowUpAsConfigProblems() async throws {
        try env.setRules(Data(#"{"schema": 1, "rules": [{"id": "x", "label": "Kuitit"}]}"#.utf8))
        let task = start()
        #expect(await eventually { !((jsonObject(env.paths.status)?["configProblems"] as? [String]) ?? []).isEmpty })
        task.cancel()
        await task.value
    }
}

/// D16: five or more unclean process starts within 10 min → safe mode. A start after a graceful stop (SIGTERM,
/// state flushed) does not count; a crash or `kill -9` leaves no marker, so the next start does.
@Suite struct StartGuardTests {
    let url = makeTempDir().appendingPathComponent("starts.json")

    @Test func fiveStartsWithinTenMinutesIsSafeMode() {
        for i in 0..<4 {
            #expect(StartGuard(url: url).recordStart(at: daemonEpoch.addingTimeInterval(Double(i) * 60)).safeMode == false)
        }
        let fifth = StartGuard(url: url).recordStart(at: daemonEpoch.addingTimeInterval(240))
        #expect(fifth.safeMode)
        #expect(fifth.starts == 5)
    }

    @Test func startsOlderThanTenMinutesDoNotCount() {
        for i in 0..<10 {
            #expect(StartGuard(url: url).recordStart(at: daemonEpoch.addingTimeInterval(Double(i) * 180)).safeMode == false)
        }
    }

    @Test func calmStartAfterACrashLoopIsNormal() {
        for i in 0..<5 { _ = StartGuard(url: url).recordStart(at: daemonEpoch.addingTimeInterval(Double(i) * 30)) }
        #expect(StartGuard(url: url).recordStart(at: daemonEpoch.addingTimeInterval(3_600)).safeMode == false)
    }

    @Test func corruptFileNeverBlocksAStart() throws {
        try Data("{oops".utf8).write(to: url)
        let result = StartGuard(url: url).recordStart(at: daemonEpoch)
        #expect(result.safeMode == false)
        #expect(result.starts == 1)
        #expect(posixMode(url) == 0o600)
    }

    func at(_ seconds: TimeInterval) -> Date { daemonEpoch.addingTimeInterval(seconds) }

    @Test func startsAfterGracefulStopsNeverCount() {
        // make daemon-restart ten times in five minutes: every stop is graceful.
        for i in 0..<10 {
            let start = StartGuard(url: url).recordStart(at: at(Double(i) * 30))
            #expect(start.safeMode == false, "start \(i)")
            #expect(start.clean == (i > 0), "start \(i)")
            #expect(start.starts == 1, "start \(i)")                    // only the very first (no marker) counted
            StartGuard(url: url).recordCleanShutdown(at: at(Double(i) * 30 + 10))
        }
        #expect(posixMode(url) == 0o600)
    }

    @Test func aCrashOrKillAfterACleanStartStillCounts() {
        StartGuard(url: url).recordCleanShutdown(at: at(0))
        #expect(StartGuard(url: url).recordStart(at: at(30)).clean)        // after the graceful stop: not counted
        // That process crashes (no marker), and so do the next ones: each restart counts.
        for i in 1...4 {
            let start = StartGuard(url: url).recordStart(at: at(30 + Double(i) * 30))
            #expect(start.clean == false)
            #expect(start.starts == i)
            #expect(start.safeMode == false)
        }
        let fifth = StartGuard(url: url).recordStart(at: at(180))
        #expect(fifth.starts == 5)
        #expect(fifth.safeMode)
    }

    @Test func theMarkerIsUsedByOneStartOnly() {
        StartGuard(url: url).recordCleanShutdown(at: at(0))
        #expect(StartGuard(url: url).recordStart(at: at(30)).clean)
        let next = StartGuard(url: url).recordStart(at: at(60))           // the clean-started process was killed
        #expect(next.clean == false)
        #expect(next.starts == 1)
    }

    @Test func uncleanStartsBeforeAGracefulStopStillCountAfterIt() {
        for i in 0..<5 { _ = StartGuard(url: url).recordStart(at: at(Double(i) * 30)) }   // crash loop: safe mode
        StartGuard(url: url).recordCleanShutdown(at: at(200))              // Matti stops it
        let clean = StartGuard(url: url).recordStart(at: at(230))
        #expect(clean.clean)
        #expect(clean.safeMode == false)                                   // a graceful stop is evidence of health
        let crash = StartGuard(url: url).recordStart(at: at(260))          // …but one more crash within the window
        #expect(crash.starts == 6)
        #expect(crash.safeMode)
    }

    @Test func theLegacyArrayFileIsStillRead() throws {
        let legacy = (0..<4).map { at(Double($0) * 30) }
        try DaemonJSON.encoder(pretty: false).encode(legacy).write(to: url)
        let fifth = StartGuard(url: url).recordStart(at: at(150))
        #expect(fifth.starts == 5)
        #expect(fifth.safeMode)
    }

    @Test func aCleanShutdownMarkerIsWritten0600() {
        StartGuard(url: url).recordCleanShutdown(at: at(0))
        #expect(posixMode(url) == 0o600)
    }
}

/// D16: safe mode lasts until the process has run 30 min without a restart, then sorting resumes by itself.
@Suite struct SafeModeTests {
    @Test func clearsAfterThirtyMinutesOfStableRunning() {
        let safe = SafeMode(active: true, since: daemonEpoch)
        #expect(safe.isActive)
        #expect(safe.snapshot.clearsAt == daemonEpoch.addingTimeInterval(1_800))
        #expect(safe.clearIfStable(now: daemonEpoch.addingTimeInterval(1_799)) == false)
        #expect(safe.isActive)
        #expect(safe.clearIfStable(now: daemonEpoch.addingTimeInterval(1_800)))
        #expect(safe.isActive == false)
        #expect(safe.snapshot.clearedAt == daemonEpoch.addingTimeInterval(1_800))
        #expect(safe.snapshot.clearsAt == nil)
        #expect(safe.clearIfStable(now: daemonEpoch.addingTimeInterval(4_000)) == false)   // once
        #expect(safe.snapshot.clearedAt == daemonEpoch.addingTimeInterval(1_800))
    }

    @Test func aNormalStartIsNeverInSafeMode() {
        let normal = SafeMode(active: false, since: daemonEpoch)
        #expect(normal.isActive == false)
        #expect(normal.clearIfStable(now: daemonEpoch.addingTimeInterval(3_600)) == false)
        #expect(normal.snapshot == SafeMode.Snapshot(active: false, clearsAt: nil, clearedAt: nil))
    }
}

/// D14: `flock` on `daemon/daemon.lock`; a busy lock makes `run` exit 75 so launchd retries.
@Suite struct InstanceLockTests {
    let url = makeTempDir().appendingPathComponent("daemon.lock")

    @Test func secondLockIsBusyUntilReleased() throws {
        let first = try InstanceLock(url)
        #expect(throws: InstanceLockError.busy) { _ = try InstanceLock(url) }
        first.release()
        let again = try InstanceLock(url)
        again.release()
    }

    @Test func lockFileIs0600() throws {
        let lock = try InstanceLock(url)
        #expect(posixMode(url) == 0o600)
        lock.release()
    }

    @Test func exitCodes() {
        #expect(DaemonExitCode.ok.rawValue == 0)
        #expect(DaemonExitCode.attention.rawValue == 1)
        #expect(DaemonExitCode.notRunning.rawValue == 2)
        #expect(DaemonExitCode.usage.rawValue == 64)
        #expect(DaemonExitCode.invalidData.rawValue == 65)
        #expect(DaemonExitCode.unavailable.rawValue == 69)
        #expect(DaemonExitCode.lockHeld.rawValue == 75)                   // launchd restarts a non-zero exit
        #expect(DaemonExitCode.wrongAccount.rawValue == 77)
    }
}
