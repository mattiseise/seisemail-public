import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §15 `mak8r-daemon` argv: every command, its options and the usage errors (exit 64).
@Suite struct DaemonCommandParseTests {
    func parse(_ line: String) throws(UsageError) -> DaemonCommand {
        try DaemonCommand.parse(line.split(separator: " ").map(String.init))
    }

    func usage(_ line: String) -> UsageError? {
        do {
            _ = try parse(line)
            return nil
        } catch {
            return error
        }
    }

    @Test func commands() throws {
        #expect(try parse("run") == .run)
        #expect(try DaemonCommand.parse([]) == .help(requested: false))
        #expect(try parse("help") == .help(requested: true))
        #expect(try parse("--help") == .help(requested: true))
        #expect(try parse("-h") == .help(requested: true))
        #expect(try parse("login Matti@Example.fi") == .login(email: "Matti@Example.fi", noBrowser: false))
        #expect(try parse("login matti@example.fi --no-browser") == .login(email: "matti@example.fi", noBrowser: true))
        #expect(try parse("login --no-browser matti@example.fi") == .login(email: "matti@example.fi", noBrowser: true))
        #expect(try DaemonCommand.parse(["login", "--callback", "http://127.0.0.1:5/?code=c"])
            == .loginCallback(url: "http://127.0.0.1:5/?code=c"))
        #expect(try parse("logout matti@example.fi") == .logout(email: "matti@example.fi"))
        #expect(try parse("status") == .status(json: false))
        #expect(try parse("status --json") == .status(json: true))
        #expect(try parse("mode wake off") == .mode(.wake, .off))
        #expect(try parse("mode sorting live") == .mode(.sorting, .live))
        #expect(try parse("mode sorting shadow") == .mode(.sorting, .shadow))
        #expect(try parse("init") == .initialize)
        #expect(try parse("rules check") == .rulesCheck)
        #expect(try parse("review") == .review(ReviewQuery()))
        #expect(try parse("review --since 3d --account a@b.fi --rule kuitit --summary")
            == .review(ReviewQuery(since: "3d", account: "a@b.fi", rule: "kuitit", summary: true)))
        #expect(try parse("explain 19a2b --account a@b.fi") == .explain(threadID: "19a2b", account: "a@b.fi"))
        #expect(try parse("explain 19a2b") == .explain(threadID: "19a2b", account: nil))
        #expect(try parse("backfill --since 3d --dry-run") == .backfill(since: "3d", account: nil, dryRun: true))
        #expect(try parse("backfill --account a@b.fi --since 2026-10-01")
            == .backfill(since: "2026-10-01", account: "a@b.fi", dryRun: false))
        #expect(try parse("once") == .once(account: nil, scope: .both))
        #expect(try parse("once --wake") == .once(account: nil, scope: .wake))
        #expect(try parse("once --sync --account a@b.fi") == .once(account: "a@b.fi", scope: .sync))
        #expect(try parse("debug invalidate-token a@b.fi") == .debugInvalidateToken(email: "a@b.fi"))
        #expect(try parse("debug note-now a@b.fi") == .debugNoteNow(email: "a@b.fi"))
    }

    @Test func usageErrors() {
        for line in ["kissa", "login", "login a@b.fi extra", "login --callback", "logout", "status --yaml",
                     "mode", "mode wake", "mode lajittelu live", "mode wake on", "rules", "rules fix",
                     "review --since", "review --bogus", "explain", "backfill", "backfill --since", "backfill 3d",
                     "once --wake --sync", "once --account", "debug", "debug invalidate-token", "debug fly a@b.fi",
                     "run now"] {
            let error = usage(line)
            #expect(error != nil, "\(line)")
            #expect(error?.message.isEmpty == false, "\(line)")
        }
        #expect(DaemonExitCode.usage.rawValue == 64)
    }

    @Test func helpNamesEveryCommandInFinnish() {
        let help = DaemonCommand.helpText
        for command in ["run", "login <osoite> [--no-browser]", "login --callback", "logout", "status [--json]",
                        "mode wake|sorting off|shadow|live", "init", "rules check", "review", "explain", "backfill --since",
                        "once", "debug invalidate-token", "debug note-now"] {
            #expect(help.contains(command), "\(command)")
        }
        #expect(help.contains("Poistumiskoodit"))
        #expect(help.contains("MAK8R_DAEMON_SUPPORT_DIR"))
    }
}

/// `MAK8R_DAEMON_SUPPORT_DIR` / `MAK8R_DAEMON_LOGS_DIR`: the CLI against a temporary folder (tests, dry runs).
@Suite struct DaemonPathsOverrideTests {
    @Test func environmentOverridesBothFolders() {
        let p = DaemonPaths.resolve(environment: ["MAK8R_DAEMON_SUPPORT_DIR": "/tmp/x/support", "MAK8R_DAEMON_LOGS_DIR": "/tmp/x/logs"])
        #expect(p.support.path == "/tmp/x/support")
        #expect(p.logs.path == "/tmp/x/logs")
        #expect(p.status.path == "/tmp/x/support/daemon/status.json")
    }

    @Test func supportAloneKeepsTheLogsBesideIt() {
        let p = DaemonPaths.resolve(environment: ["MAK8R_DAEMON_SUPPORT_DIR": "/tmp/x/support"])
        #expect(p.logs.path == "/tmp/x/support/logs")
    }

    @Test func noOverrideIsLive() {
        #expect(DaemonPaths.resolve(environment: [:]) == DaemonPaths.live)
        #expect(DaemonPaths.resolve(environment: ["MAK8R_DAEMON_SUPPORT_DIR": ""]) == DaemonPaths.live)
    }
}

/// `init` and `mode` (§15): `daemon.json` and `rules.json` only when missing; `mode` edits one field atomically.
/// `daemon.json` is always 0600 (it names the notify hook's argv; §9.1) and never made more permissive.
@Suite struct DaemonSetupTests {
    let root = makeTempDir()
    var paths: DaemonPaths { DaemonPaths(support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs")) }

    @Test func initCreatesTheFoldersAndBothFilesOnce() throws {
        let created = try DaemonSetup.initialize(paths: paths)
        #expect(Set(created.map(\.lastPathComponent)) == ["daemon.json", "rules.json"])
        #expect(try Data(contentsOf: paths.rules) == Data(DefaultRules.json.utf8))
        #expect(try DaemonConfig.decode(Data(contentsOf: paths.config)) == DaemonConfig())
        #expect(posixMode(paths.config) == 0o600)
        #expect(posixMode(paths.rules) == 0o644)
        for dir in [paths.daemon, paths.tokens, paths.requests, paths.logs] {
            #expect(posixMode(dir) == 0o700, "\(dir.lastPathComponent)")
        }
        try Data("{\"schema\": 1, \"sorting\": \"live\"}".utf8).write(to: paths.config)
        #expect(try DaemonSetup.initialize(paths: paths).isEmpty)
        #expect(try DaemonConfig.decode(Data(contentsOf: paths.config)).sorting == .live)
    }

    @Test func modeChangesOneFieldAndKeepsTheRest() throws {
        try paths.createDirectories()
        var config = DaemonConfig()
        config.disabledAccounts = ["toinen@example.fi"]
        config.notify.reminderHour = 8
        try config.encoded().write(to: paths.config)
        let updated = try DaemonSetup.setMode(.sorting, .live, paths: paths)
        #expect(updated.sorting == .live)
        let onDisk = try DaemonConfig.decode(Data(contentsOf: paths.config))
        #expect(onDisk.sorting == .live)
        #expect(onDisk.wake == .live)
        #expect(onDisk.disabledAccounts == ["toinen@example.fi"])
        #expect(onDisk.notify.reminderHour == 8)
        #expect(posixMode(paths.config) == 0o600)                         // the 0644 file Matti wrote is narrowed
        #expect(try DaemonSetup.setMode(.wake, .off, paths: paths).wake == .off)
        #expect(try DaemonConfig.decode(Data(contentsOf: paths.config)).sorting == .live)
    }

    @Test func modeWithoutAFileStartsFromTheDefaults() throws {
        let updated = try DaemonSetup.setMode(.wake, .shadow, paths: paths)
        #expect(updated == DaemonConfig(wake: .shadow))
        #expect(try DaemonConfig.decode(Data(contentsOf: paths.config)) == DaemonConfig(wake: .shadow))
        #expect(posixMode(paths.config) == 0o600)
    }

    @Test func modeNeverWidensAnExistingFile() throws {
        try paths.createDirectories()
        for mode in [0o400, 0o600] {
            try DaemonConfig().encoded().write(to: paths.config)
            try setPosixMode(paths.config, mode)
            _ = try DaemonSetup.setMode(.sorting, .live, paths: paths)
            #expect(posixMode(paths.config) == mode, "\(String(mode, radix: 8))")
            #expect(try DaemonConfig.decode(Data(contentsOf: paths.config)).sorting == .live)
            try setPosixMode(paths.config, 0o600)
        }
    }

    @Test func groupOrOtherBitsAreDroppedWhateverTheExistingMode() throws {
        try paths.createDirectories()
        for (existing, expected) in [(0o664, 0o600), (0o640, 0o600), (0o444, 0o400), (0o604, 0o600)] {
            try DaemonConfig().encoded().write(to: paths.config)
            try setPosixMode(paths.config, existing)
            _ = try DaemonSetup.setMode(.wake, .shadow, paths: paths)
            #expect(posixMode(paths.config) == expected, "\(String(existing, radix: 8))")
            try setPosixMode(paths.config, 0o600)
        }
    }

    @Test func initTightensAnExistingConfigWithoutRewritingIt() throws {
        try paths.createDirectories()
        let mine = Data("{\"schema\": 1, \"sorting\": \"live\"}".utf8)
        try mine.write(to: paths.config)
        try setPosixMode(paths.config, 0o644)
        let created = try DaemonSetup.initialize(paths: paths)
        #expect(created.map(\.lastPathComponent) == ["rules.json"])
        #expect(try Data(contentsOf: paths.config) == mine)
        #expect(posixMode(paths.config) == 0o600)
        try setPosixMode(paths.config, 0o400)                              // narrower than 0600 stays as it is
        _ = try DaemonSetup.initialize(paths: paths)
        #expect(posixMode(paths.config) == 0o400)
    }

    @Test func modeRefusesToOverwriteAnInvalidFile() throws {
        try paths.createDirectories()
        let broken = Data("{\"schema\": 1, \"sortng\": \"live\"}".utf8)
        try broken.write(to: paths.config)
        #expect(throws: ConfigError.self) { try DaemonSetup.setMode(.sorting, .live, paths: paths) }
        #expect(try Data(contentsOf: paths.config) == broken)
    }
}

/// `status [--json]` (§9.4, §15): the text Matti reads, the JSON local monitors read, and the exit codes 0/1/2.
@Suite struct StatusReportTests {
    let now = daemonEpoch

    func status(accounts: [AccountStatus] = [], safeMode: Bool = false, problems: [String] = [], error: String? = nil,
                writtenAgo: TimeInterval = 20, state: String = "running", sorting: FeatureMode = .shadow) -> DaemonStatus {
        DaemonStatus(pid: 4242, build: "92", state: state, startedAt: now.addingTimeInterval(-3_600),
                     writtenAt: now.addingTimeInterval(-writtenAgo), safeMode: safeMode,
                     modes: .init(wake: .live, sorting: sorting), configProblems: problems, error: error, accounts: accounts)
    }

    func running(_ edit: (inout AccountStatus) -> Void = { _ in }) -> AccountStatus {
        var a = AccountStatus(email: "matti@example.fi", phase: "running", expiresAt: D(1_791_785_520),
                              lastWakeAt: now.addingTimeInterval(-28), lastWakeResult: "ok",
                              lastSyncAt: now.addingTimeInterval(-10), lastSyncResult: "ok", watermarkAgeSeconds: 41,
                              sentBackfill: "done", skewSeconds: 0.4, unitsLastMinute: 37,
                              today: .init(woken: 2, cancelled: 0, cleaned: 1, classified: 12, propagated: 4, unmatched: 3))
        edit(&a)
        return a
    }

    @Test func missingStatusMeansNotRunning() {
        let (text, code) = StatusReport.render(nil, now: now)
        #expect(code == .notRunning)
        #expect(text.contains("Daemon ei ole käynnissä"))
    }

    @Test func staleStatusSaysTheDaemonDoesNotAnswer() {
        let (text, code) = StatusReport.render(status(accounts: [running()], writtenAgo: 181), now: now)
        #expect(code == .notRunning)
        #expect(text.contains("daemon ei vastaa"))
    }

    @Test func stoppedStatus() {
        let (text, code) = StatusReport.render(status(state: "stopped"), now: now)
        #expect(code == .notRunning)
        #expect(text.contains("pysäytetty"))
    }

    @Test func runningWithoutAccounts() {
        let (text, code) = StatusReport.render(status(), now: now)
        #expect(code == .ok)
        #expect(text.contains("Daemon käynnissä, ei tilejä"))
        #expect(text.contains("mak8r-daemon login"))
    }

    @Test func healthyAccount() {
        let (text, code) = StatusReport.render(status(accounts: [running()]), now: now)
        #expect(code == .ok)
        #expect(text.contains("matti@example.fi: käynnissä"))
        #expect(text.contains("herätys live"))
        #expect(text.contains("lajittelu shadow (varjotila"))
        #expect(text.contains("Kirjautuminen voimassa ma 12.10. klo 9.12 asti"))
        #expect(text.contains("lähetettyjen välimuisti: valmis"))
        #expect(text.contains("luokiteltu 12"))
        #expect(!text.contains("KIRJAUDU UUDELLEEN"))
    }

    @Test func sentBackfillProgress() {
        let account = running {
            $0.phase = "backfillingSent"
            $0.sentBackfill = "running"
            $0.sentBackfillProgress = "1500/5000"
        }
        let (text, code) = StatusReport.render(status(accounts: [account]), now: now)
        #expect(code == .ok)
        #expect(text.contains("lähetettyjen välimuisti: rakennetaan (1500/5000)"))
    }

    @Test func needsLoginNeedsAttention() {
        let account = running {
            $0.phase = "needsLogin"
            $0.reason = "expired"
            $0.attention = "KIRJAUDU UUDELLEEN"
            $0.action = "Kirjaudu uudelleen: mak8r-daemon login matti@example.fi"
        }
        let (text, code) = StatusReport.render(status(accounts: [account]), now: now)
        #expect(code == .attention)
        #expect(code.rawValue == 1)
        #expect(text.contains("KIRJAUDU UUDELLEEN"))
        #expect(text.contains("mak8r-daemon login matti@example.fi"))
    }

    @Test func offlineIsShown() {
        let account = running { $0.lastSyncResult = "offline"; $0.lastWakeResult = "offline" }
        let (text, _) = StatusReport.render(status(accounts: [account]), now: now)
        #expect(text.contains("ei verkkoyhteyttä"))
    }

    @Test func safeModeAndConfigProblemsNeedAttention() {
        let (safe, safeCode) = StatusReport.render(status(safeMode: true, sorting: .off), now: now)
        #expect(safeCode == .attention)
        #expect(safe.contains("TURVATILA"))
        let (bad, badCode) = StatusReport.render(status(problems: ["rules.json: tuntematon avain x"]), now: now)
        #expect(badCode == .attention)
        #expect(bad.contains("rules.json: tuntematon avain x"))
        let (oauth, oauthCode) = StatusReport.render(status(error: "OAuth-asiakas puuttuu"), now: now)
        #expect(oauthCode == .attention)
        #expect(oauth.contains("OAuth-asiakas puuttuu"))
    }

    // shadowSince / liveSince (§9.4, §16): shown in Finnish and as a value `backfill --since` accepts.
    let shadowStart = D(1_791_111_720)                                     // su 4.10. 14.02 (+03)
    let liveStart = D(1_791_181_800)                                       // ma 5.10. 9.30

    @Test func shadowStartIsShownWithItsBackfillSince() {
        let (text, code) = StatusReport.render(status(accounts: [running { $0.shadowSince = shadowStart }]), now: now)
        #expect(code == .ok)
        #expect(text.contains("  lajittelu varjotilassa 4.10. klo 14.02 alkaen (backfill --since 2026-10-04)"))
    }

    @Test func shadowAndLiveStartsAreBothShown() {
        let account = running {
            $0.shadowSince = shadowStart
            $0.liveSince = liveStart
        }
        let (text, _) = StatusReport.render(status(accounts: [account], sorting: .live), now: now)
        #expect(text.contains("  lajittelu varjotilassa 4.10. klo 14.02 alkaen, live-tilassa 5.10. klo 9.30 alkaen "
            + "(varjojakson ketjut: backfill --since 2026-10-04)"))
    }

    @Test func liveWithoutAShadowPeriodHasNoBackfillHint() {
        let (text, _) = StatusReport.render(status(accounts: [running { $0.liveSince = liveStart }], sorting: .live), now: now)
        #expect(text.contains("  lajittelu live-tilassa 5.10. klo 9.30 alkaen"))
        #expect(!text.contains("backfill --since"))
    }

    @Test func unknownStartsPrintNothing() {
        let (text, _) = StatusReport.render(status(accounts: [running()]), now: now)
        #expect(!text.contains("alkaen"))
    }

    @Test func theSinceValueIsAcceptedByBackfillAndCoversTheShadowStart() throws {
        #expect(BackfillRequest.sinceArgument(shadowStart) == "2026-10-04")
        #expect(BackfillRequest.sinceArgument(D(1_791_149_400)) == "2026-10-05")   // 0.30 Helsinki, still 4.10. in UTC
        let since = try #require(BackfillRequest.parseSince(BackfillRequest.sinceArgument(shadowStart), now: now))
        #expect(since <= shadowStart)
        #expect(shadowStart.timeIntervalSince(since) < 86_400)
    }

    @Test func modeLiveNamesTheBackfillCommandPerAccount() {
        let one = status(accounts: [running { $0.shadowSince = shadowStart }])
        #expect(StatusReport.backfillCommands(one) == ["mak8r-daemon backfill --since 2026-10-04 --dry-run"])
        let two = status(accounts: [running { $0.shadowSince = shadowStart },
                                    running { $0.email = "toinen@example.fi" },
                                    running { $0.email = "kolmas@example.fi"; $0.shadowSince = liveStart }])
        #expect(StatusReport.backfillCommands(two) == [
            "mak8r-daemon backfill --since 2026-10-04 --account matti@example.fi --dry-run",
            "mak8r-daemon backfill --since 2026-10-05 --account kolmas@example.fi --dry-run",
        ])
        #expect(StatusReport.backfillCommands(nil).isEmpty)
    }

    @Test func jsonCarriesTheStartsAndNullWhenUnknown() throws {
        let (text, _) = StatusReport.json(status(accounts: [running { $0.shadowSince = shadowStart }]), now: now)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let account = try #require((object["accounts"] as? [[String: Any]])?.first)
        #expect((account["shadowSince"] as? String).flatMap { parseISO($0) } == shadowStart)
        #expect(account["liveSince"] is NSNull)
    }

    @Test func safeModeSaysWhenItEndsAndThatItEnded() throws {
        var active = status(safeMode: true, sorting: .off)
        active.safeModeUntil = now.addingTimeInterval(600)
        let (text, code) = StatusReport.render(active, now: now)
        #expect(code == .attention)
        #expect(text.contains("TURVATILA"))
        #expect(text.contains("poistuu itsestään \(FinnishTime.compact(now.addingTimeInterval(600), now: now))"))
        var cleared = status()
        cleared.safeModeClearedAt = now.addingTimeInterval(-300)
        let (after, afterCode) = StatusReport.render(cleared, now: now)
        #expect(afterCode == .ok)                                           // informational once it has ended
        #expect(!after.contains("TURVATILA"))
        #expect(after.contains("Turvatila päättyi \(FinnishTime.compact(now.addingTimeInterval(-300), now: now))"))
        let decoded = try DaemonJSON.decoder().decode(DaemonStatus.self, from: Data(StatusReport.json(active, now: now).text.utf8))
        #expect(decoded.safeModeUntil == active.safeModeUntil)
    }

    @Test func jsonIsTheFileWithTheSameExitCodes() throws {
        let s = status(accounts: [running()])
        let (text, code) = StatusReport.json(s, now: now)
        #expect(code == .ok)
        let decoded = try DaemonJSON.decoder().decode(DaemonStatus.self, from: Data(text.utf8))
        #expect(decoded.accounts.first?.email == "matti@example.fi")
        #expect(StatusReport.json(status(writtenAgo: 600), now: now).code == .notRunning)
        let (missing, missingCode) = StatusReport.json(nil, now: now)
        #expect(missingCode == .notRunning)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(missing.utf8)) as? [String: Any])
        #expect(object["state"] as? String == "missing")
    }
}

/// `review` (§15, §16 stage 2): `decisions.jsonl` and its rotations, filtered and summarised.
@Suite struct ReviewReportTests {
    let root = makeTempDir()
    let now = daemonEpoch
    var paths: DaemonPaths { DaemonPaths(support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs")) }

    func entry(_ thread: String, ago: TimeInterval, decision: String = "classify", rule: String? = "kuitit",
               label: String? = "Lajittelu/Kuitit", also: [String]? = nil, account: String = "matti@example.fi",
               mode: String = "shadow") -> DecisionEntry {
        DecisionEntry(at: now.addingTimeInterval(-ago), mode: mode, account: account, thread: thread, msg: "m-\(thread)",
                      decision: decision, rule: rule, label: label, alsoMatched: also, from: "kauppa@example.fi",
                      subject: "Kuitti \u{202E}tilauksesta\nX")
    }

    func write(_ entries: [DecisionEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = DaemonJSON.encoder(pretty: false)
        let text = try entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
        try Data((text + "\n").utf8).write(to: url)
    }

    @Test func readsRotationsOldestFirst() throws {
        try write([entry("t3", ago: 300)], to: URL(fileURLWithPath: paths.decisions.path + ".2"))
        try write([entry("t2", ago: 200)], to: URL(fileURLWithPath: paths.decisions.path + ".1"))
        try write([entry("t1", ago: 100)], to: paths.decisions)
        try Data("not json\n".utf8).write(to: URL(fileURLWithPath: paths.decisions.path + ".3"))
        #expect(ReviewReport.load(paths: paths).map(\.thread) == ["t3", "t2", "t1"])
    }

    @Test func filters() throws {
        let entries = [
            entry("old", ago: 2 * 86_400),
            entry("k", ago: 60),
            entry("i", ago: 60, rule: "ihmiset", label: "Lajittelu/Ihmiset", also: ["kuitit"]),
            entry("u", ago: 60, decision: "unmatched", rule: nil, label: nil),
            entry("other", ago: 60, account: "toinen@example.fi"),
        ]
        #expect(try ReviewReport.filter(entries, ReviewQuery(), now: now).map(\.thread) == ["k", "i", "u", "other"])
        #expect(try ReviewReport.filter(entries, ReviewQuery(since: "3d"), now: now).count == 5)
        #expect(try ReviewReport.filter(entries, ReviewQuery(rule: "kuitit"), now: now).map(\.thread) == ["k", "i", "other"])
        #expect(try ReviewReport.filter(entries, ReviewQuery(account: "Toinen@example.fi"), now: now).map(\.thread) == ["other"])
        #expect(throws: UsageError.self) { try ReviewReport.filter(entries, ReviewQuery(since: "eilen"), now: now) }
    }

    @Test func sinceForms() {
        #expect(ReviewReport.parseSince("24h", now: now) == now.addingTimeInterval(-86_400))
        #expect(ReviewReport.parseSince("90min", now: now) == now.addingTimeInterval(-5_400))
        #expect(ReviewReport.parseSince("2d", now: now) == BackfillRequest.parseSince("2d", now: now))
        #expect(ReviewReport.parseSince("2026-10-01", now: now) != nil)
        #expect(ReviewReport.parseSince("0h", now: now) == nil)
        #expect(ReviewReport.parseSince("x", now: now) == nil)
    }

    @Test func linesShowTheDecisionWithoutControlCharacters() {
        let text = ReviewReport.render([entry("t1", ago: 60, also: ["ihmiset"])], summary: false, now: now)
        #expect(text.contains("VARJO"))
        #expect(text.contains("kuitit → Lajittelu/Kuitit"))
        #expect(text.contains("myös: ihmiset"))
        #expect(text.contains("kauppa@example.fi"))
        #expect(text.contains("t1"))
        #expect(!text.contains("\u{202E}"))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test func emptyReview() {
        #expect(ReviewReport.render([], summary: false, now: now).contains("Ei päätöksiä"))
    }

    @Test func summaryCountsDecisionsRulesAndOverlaps() {
        let entries = [
            entry("a", ago: 60), entry("b", ago: 60, also: ["ihmiset"]),
            entry("c", ago: 60, rule: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", also: ["kuitit", "ihmiset"]),
            entry("d", ago: 60, decision: "unmatched", rule: nil, label: nil),
            entry("e", ago: 60, decision: "propagate", rule: nil, label: nil),
        ]
        let text = ReviewReport.render(entries, summary: true, now: now)
        #expect(text.contains("Päätöksiä 5"))
        #expect(text.contains("luokiteltu: 3"))
        #expect(text.contains("kuitit: 2"))
        #expect(text.contains("uutiskirjeet: 1"))
        #expect(text.contains("ei osumaa: 1"))
        #expect(text.contains("periytetty: 1"))
        #expect(text.contains("kuitit + ihmiset: 1"))
        #expect(text.contains("uutiskirjeet + kuitit: 1"))
    }
}

/// `rules check` (§7.2, §15): the effective rules, exit 65 when the file is refused.
@Suite struct RulesReportTests {
    let root = makeTempDir()
    var paths: DaemonPaths { DaemonPaths(support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs")) }

    @Test func missingFileUsesTheDefaults() {
        let (text, code) = RulesReport.check(paths: paths)
        #expect(code == .ok)
        #expect(text.contains("oletussäännöt"))
        #expect(text.contains("kuitit-suodattimet"))
        #expect(text.contains("ilmoitukset-laaja"))
        #expect(text.contains("pois päältä"))
        #expect(text.contains("Lajittelu/Ihmiset"))
    }

    @Test func validFileIsListedInOrder() throws {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try Rules.defaultsData(disabling: ["kuitit"]).write(to: paths.rules)
        let (text, code) = RulesReport.check(paths: paths)
        #expect(code == .ok)
        #expect(text.contains("rules.json kunnossa"))
        let lines = text.split(separator: "\n").map(String.init)
        let first = try #require(lines.firstIndex { $0.contains("kuitit-suodattimet") })
        let news = try #require(lines.firstIndex { $0.contains("uutiskirjeet") })
        #expect(first < news)
        #expect(lines.contains { $0.contains("kuitit ") && $0.contains("pois päältä") })
    }

    @Test func invalidFileExits65WithTheProblem() throws {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "me": [], "options": {"deferAutoReplyInMyThreads": true}, "rules": [{"id": "x", "enabled": true, "label": "Muut/X", "any": [{"type": "headerPresent", "header": "List-Id"}]}]}"#.utf8)
            .write(to: paths.rules)
        let (text, code) = RulesReport.check(paths: paths)
        #expect(code == .invalidData)
        #expect(code.rawValue == 65)
        #expect(text.contains("Lajittelu/"))
        #expect(text.contains("käytössä"))
    }
}

/// `explain <threadId>` (§15): the full trace of one fresh read, rendered without Gmail.
@Suite struct ExplainReportTests {
    @Test func classifiedThread() {
        let thread = Mail.thread("t9", [
            Mail.msg("m1", from: "Kauppa <kauppa@example.fi>", subject: "Tilausvahvistus", at: -60),
            Mail.msg("m2", from: "Kauppa <kauppa@example.fi>", subject: "Kuitti tilauksestasi", at: 0,
                     headers: ["List-Unsubscribe": "<mailto:u@example.fi>"]),
        ])
        let text = ExplainReport.render(thread: thread, labels: Snap.snapshot, rules: CompiledRules.defaults,
                                        sent: sentCache(["kauppa@example.fi"]), me: [Mail.me], now: daemonEpoch)
        #expect(text.contains("Ketju t9"))
        #expect(text.contains("Ratkaiseva viesti: m2"))
        #expect(text.contains("kauppa@example.fi"))
        #expect(text.contains("kuitti"))
        #expect(text.contains("uutiskirjeet: osuu"))
        #expect(text.contains("kuitit: osuu"))
        #expect(text.contains("ihmiset: osuu"))
        #expect(text.contains("ilmoitukset-laaja: pois päältä"))
        #expect(text.contains("Päätös: classify uutiskirjeet → Lajittelu/Uutiskirjeet"))
        #expect(text.contains("Lajittelu/Luokiteltu"))
        #expect(text.contains("(varjo: mitään ei kirjoitettu)"))
    }

    @Test func manualRemovalAndPropagationAreExplained() {
        let kept = Mail.thread("t1", [Mail.msg("m1", labels: ["INBOX", Snap.marker])])
        let keptText = ExplainReport.render(thread: kept, labels: Snap.snapshot, rules: CompiledRules.defaults,
                                            sent: SentCache(), me: [Mail.me], now: daemonEpoch)
        #expect(keptText.contains("Päätös: manualKept"))

        let propagated = Mail.thread("t2", [Mail.msg("m1", labels: ["INBOX", Snap.kuitit, Snap.marker], at: -60),
                                            Mail.msg("m2", at: 0)])
        let propText = ExplainReport.render(thread: propagated, labels: Snap.snapshot, rules: CompiledRules.defaults,
                                            sent: SentCache(), me: [Mail.me], now: daemonEpoch)
        #expect(propText.contains("Päätös: propagate"))
        #expect(propText.contains("Lajittelu/Kuitit"))
    }

    @Test func sentOnlyThreadIsIgnored() {
        let thread = Mail.thread("t3", [Mail.sent("s1")])
        let text = ExplainReport.render(thread: thread, labels: Snap.snapshot, rules: CompiledRules.defaults,
                                        sent: SentCache(), me: [Mail.me], now: daemonEpoch)
        #expect(text.contains("Päätös: ignore"))
        #expect(text.contains("Ratkaiseva viesti: ei"))
    }
}

/// `backfill` and the account choice for commands with `--account`.
@Suite struct BackfillCommandTests {
    let root = makeTempDir()
    var paths: DaemonPaths { DaemonPaths(support: root.appendingPathComponent("support"), logs: root.appendingPathComponent("logs")) }

    func login(_ email: String) throws {
        try paths.createDirectories()
        try FileTokenStore.write(StoredToken(account: email, clientID: "cid", refreshToken: "r-\(email)", consentedAt: daemonEpoch),
                                 to: paths.token(email))
    }

    @Test func accountChoice() throws {
        #expect(throws: UsageError.self) { try AccountChoice.resolve(nil, paths: paths) }   // nobody signed in
        try login("matti@example.fi")
        #expect(try AccountChoice.resolve(nil, paths: paths) == "matti@example.fi")
        #expect(try AccountChoice.resolve("Matti@Example.fi", paths: paths) == "matti@example.fi")
        #expect(throws: UsageError.self) { try AccountChoice.resolve("toinen@example.fi", paths: paths) }
        try login("toinen@example.fi")
        #expect(throws: UsageError.self) { try AccountChoice.resolve(nil, paths: paths) }   // ambiguous
        #expect(try AccountChoice.resolve("toinen@example.fi", paths: paths) == "toinen@example.fi")
    }

    @Test func requestFileHoldsSinceAndRequestedAt() throws {
        try login("matti@example.fi")
        let url = try BackfillCommand.request(since: "3d", account: nil, paths: paths, now: daemonEpoch)
        #expect(url.lastPathComponent.hasPrefix("backfill-matti@example.fi-"))
        let object = try #require(jsonObject(url))
        #expect(Set(object.keys) == ["since", "requestedAt"])
        #expect(posixMode(url) == 0o600)
        let read = try #require(BackfillRequest.read(url, account: "matti@example.fi"))
        #expect(read.since == BackfillRequest.parseSince("3d", now: daemonEpoch))
        #expect(throws: UsageError.self) { try BackfillCommand.request(since: "eilen", account: nil, paths: paths, now: daemonEpoch) }
    }

    @Test func dryRunCountsInboxThreadsAndEstimates() async throws {
        let fake = SyncFakeGmail(me: "matti@example.fi", now: { daemonEpoch })
        for i in 0..<3 { fake.deliver("t\(i)", at: daemonEpoch.addingTimeInterval(-Double(i) * 3_600)) }
        fake.deliver("old", at: daemonEpoch.addingTimeInterval(-10 * 86_400))
        let since = try #require(BackfillRequest.parseSince("3d", now: daemonEpoch))
        let count = try await BackfillCommand.countInbox(api: fake, since: since)
        #expect(count == BackfillCommand.Count(threads: 3, complete: true))
        let text = BackfillCommand.dryRunText(count: count, since: since, mode: .shadow, now: daemonEpoch)
        #expect(text.contains("3 ketjua"))
        #expect(text.contains("yksikköä"))
        #expect(text.contains("varjotila"))
        #expect(fake.writes.isEmpty)
    }
}

/// `debug invalidate-token` and `debug note-now` (§15, §22 steps 24 and 26).
@Suite struct DebugCommandTests {
    @Test func invalidateKeepsEverythingButTheRefreshToken() throws {
        let env = try DaemonEnv()
        let before = try env.writeToken("r-good")
        let after = try FileTokenStore.invalidate(at: env.paths.token(env.email))
        #expect(after.refreshToken != before.refreshToken)
        #expect(after.account == before.account)
        #expect(after.clientID == before.clientID)
        #expect(after.consentedAt == before.consentedAt)
        #expect(try FileTokenStore(fileURL: env.paths.token(env.email), readOnly: true).read() == after)
        #expect(posixMode(env.paths.token(env.email)) == 0o600)
        #expect(throws: (any Error).self) { try FileTokenStore.invalidate(at: env.paths.token("ei@ole.fi")) }
    }

    @Test func noteRequestIsHandledByTheRunningDaemonOnce() async throws {
        let env = try DaemonEnv()
        try env.writeToken("r1")
        try env.setConfig(sorting: .off)
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(env.fake.inserted.isEmpty)

        let url = try NoteRequest(account: env.email, requestedAt: env.clock.now()).write(paths: env.paths)
        #expect(url.lastPathComponent.hasPrefix("note-matti@example.fi-"))
        _ = await runner.syncTick()
        #expect(env.fake.inserted.count == 1)
        #expect(env.fake.inserted.first?.labelIDs == InboxNote.labelIDs)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect((env.storedAuth?["noteThreadIDs"] as? [String])?.count == 1)
        #expect(env.storedAuth?["warned"] as? [Int] == [])     // a test note does not count as a warning
        _ = await runner.syncTick()
        #expect(env.fake.inserted.count == 1)
    }

    @Test func noteRequestForAnotherAccountIsLeftAlone() async throws {
        let env = try DaemonEnv()
        try env.writeToken("r1")
        try env.seedState(watermark: "1000")
        let url = try NoteRequest(account: "toinen@example.fi", requestedAt: env.clock.now()).write(paths: env.paths)
        _ = await env.runner().syncTick()
        #expect(env.fake.inserted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

/// `ShadowWrite.summary`: one log/CLI line per swallowed write, never a label name the sender chose.
@Suite struct ShadowWriteSummaryTests {
    @Test func summaries() {
        #expect(ShadowWrite.modify(thread: "t1", add: ["L1", "L2"], remove: []).summary == "modify t1 add=L1,L2 remove=")
        #expect(ShadowWrite.createLabel("Lajittelu/Kuitit").summary == "labels.create")
        #expect(ShadowWrite.deleteLabel("L9").summary == "labels.delete L9")
        #expect(ShadowWrite.insert.summary == "messages.insert")
        #expect(ShadowWrite.batchModify(3).summary == "batchModify 3")
    }
}

/// What `explain` and `once` read and print beside the pure reports.
@Suite struct CLIReadOnlyTests {
    @Test func peekReadsTheStateWithoutTouchingIt() throws {
        let env = try DaemonEnv()
        try env.writeToken("r1")
        try env.seedState(watermark: "4242", sent: ["anna@example.fi": 1_791_000_000])
        let url = env.paths.state(env.email)
        let state = try #require(StateStore.peek(url))
        #expect(state.watermark.historyId == "4242")
        #expect(state.sent.contains("anna@example.fi"))

        try Data("{ torn".utf8).write(to: url)
        #expect(StateStore.peek(url) == nil)
        #expect(try Data(contentsOf: url) == Data("{ torn".utf8))      // never quarantined by a reader
        let siblings = try FileManager.default.contentsOfDirectory(atPath: env.paths.daemon.path)
        #expect(!siblings.contains { $0.contains("corrupt") })
    }

    @Test func tickTexts() {
        #expect(StatusReport.wakeText(.completed(woken: 1, cancelled: 0, nextWakeAt: nil)) == "ok, herätetty 1, peruttu 0")
        #expect(StatusReport.wakeText(.paused).contains("tauolla"))
        var outcome = SyncOutcome(result: .ok, stage: .replay)
        outcome.counts.threads = 2
        outcome.counts.classified = 1
        #expect(StatusReport.syncText(outcome).hasPrefix("ok [replay]: ketjuja 2, luokiteltu 1"))
        #expect(StatusReport.syncText(.skipped("off")) == "ohitettu (off)")
        #expect(StatusReport.syncText(SyncOutcome(result: .offline)) == "ei verkkoyhteyttä")
    }
}
