import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §5 `DaemonPaths`, `DaemonConfig` defaults (D10, §21 defaults) and `ConfigStore` (last good copy, mtime reload).
@Suite struct DaemonPathsTests {
    let support = URL(fileURLWithPath: "/tmp/mak8r/support")
    let logs = URL(fileURLWithPath: "/tmp/mak8r/logs")

    @Test func layout() {
        let p = DaemonPaths(support: support, logs: logs)
        #expect(p.support.path == "/tmp/mak8r/support")
        #expect(p.daemon.path == "/tmp/mak8r/support/daemon")
        #expect(p.tokens.path == "/tmp/mak8r/support/daemon/tokens")
        #expect(p.requests.path == "/tmp/mak8r/support/daemon/requests")
        #expect(p.bin.path == "/tmp/mak8r/support/bin")
        #expect(p.logs.path == "/tmp/mak8r/logs")
        #expect(p.config.path == "/tmp/mak8r/support/daemon.json")
        #expect(p.rules.path == "/tmp/mak8r/support/rules.json")
        #expect(p.status.path == "/tmp/mak8r/support/daemon/status.json")
        #expect(p.starts.path == "/tmp/mak8r/support/daemon/starts.json")
        #expect(p.lock.path == "/tmp/mak8r/support/daemon/daemon.lock")
        #expect(p.loginPending.path == "/tmp/mak8r/support/daemon/login-pending.json")
        #expect(p.token("Matti@Example.fi").path == "/tmp/mak8r/support/daemon/tokens/matti@example.fi.json")
        #expect(p.state("Matti@Example.fi").path == "/tmp/mak8r/support/daemon/state-matti@example.fi.json")
    }

    @Test func liveUsesTheAppFolders() {
        #expect(DaemonPaths.live.support.standardizedFileURL == AppPaths.supportDirectory.standardizedFileURL)
        #expect(DaemonPaths.live.logs.standardizedFileURL == AppPaths.logsDirectory.standardizedFileURL)
    }

    @Test func keyIsLowercasedAndEscaped() {
        #expect(DaemonPaths.key("Maija.Meikalainen+mail@Gmail.com") == "maija.meikalainen+mail@gmail.com")
        #expect(DaemonPaths.key("a b/c@x.fi") == "a%20b%2Fc@x.fi")
        #expect(DaemonPaths.key("ä@x.fi") == "%C3%A4@x.fi")
        #expect(DaemonPaths.key("../x@y.fi") == "..%2Fx@y.fi")
        #expect(!DaemonPaths.key("a/../../b@x.fi").contains("/"))
    }
}

@Suite struct DaemonConfigTests {
    @Test func defaults() {
        let c = DaemonConfig()
        #expect(c.schema == 1)
        #expect(c.wake == .live)                                         // Q13
        #expect(c.sorting == .shadow)
        #expect(c.disabledAccounts.isEmpty)
        #expect(c.notify.inboxNote)
        #expect(c.notify.warnHours == [24, 3])
        #expect(c.notify.command == nil)                                 // Q12: the hook is opt-in
        #expect(c.notify.reminderHour == 9)
        #expect(c.sync.unitsPerMinute == 2_000)
        #expect(c.sync.sweepMinutes == 30)
        #expect(c.sync.sweepWindowHours == 2)
        #expect(c.sync.resyncMaxDays == 30)
        #expect(c.sentBackfill.days == 730)                              // Q14
        #expect(c.sentBackfill.maxMessages == 5_000)
    }

    @Test func roundTrip() throws {
        var c = DaemonConfig()
        c.sorting = .live
        c.disabledAccounts = ["toinen@example.fi"]
        c.notify.command = ["/usr/local/bin/ilmoita", "--tg"]
        let decoded = try JSONDecoder().decode(DaemonConfig.self, from: JSONEncoder().encode(c))
        #expect(decoded == c)
    }

    /// D8: the sorter's pace leaves wakes at least 1,000 of the daemon's 3,000/min, whatever daemon.json says.
    @Test(arguments: [(100, true), (2_000, true), (99, false), (2_001, false), (3_000, false)])
    func unitsPerMinuteKeepsTheWakeReserve(_ value: Int, _ valid: Bool) throws {
        var c = DaemonConfig()
        c.sync.unitsPerMinute = value
        let data = try JSONEncoder().encode(c)
        if valid {
            #expect(try DaemonConfig.decode(data).sync.unitsPerMinute == value)
        } else {
            #expect(throws: ConfigError.self) { try DaemonConfig.decode(data) }
        }
    }

    @Test func modesAreLowercaseStrings() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(DaemonConfig())) as? [String: Any])
        #expect(object["wake"] as? String == "live")
        #expect(object["sorting"] as? String == "shadow")
    }
}

@Suite struct ConfigStoreTests {
    let env: DaemonEnv

    init() throws {
        env = try DaemonEnv()
    }

    /// The decision for one new incoming newsletter under the store's current rules.
    func newsletterDecision(_ rules: CompiledRules) -> SortingDecision {
        let m = Mail.msg("m1", from: "Uutiset <u@lehti.fi>", subject: "Kuitti", headers: ["List-Id": "<x>"])
        return decide(Mail.thread("t1", [m]), new: ["m1"], rules: rules).0
    }

    let receiptsOnly = Data(#"""
    {"schema": 1, "me": [], "options": {"deferAutoReplyInMyThreads": true}, "rules": [
      {"id": "vain-kuitit", "enabled": true, "label": "Lajittelu/Kuitit", "any": [{"type": "subjectToken", "pattern": "kuitti"}]}
    ]}
    """#.utf8)

    @Test func noFilesMeansDefaults() async {
        let (config, rules, problems) = await env.configStore.current()
        #expect(config == DaemonConfig())
        #expect(problems.isEmpty)
        #expect(newsletterDecision(rules) == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet",
                                                       alsoMatched: ["kuitit"]))
    }

    @Test func changedRulesAreReadOnTheNextCall() async throws {
        _ = await env.configStore.current()
        try env.setRules(receiptsOnly)
        let (_, rules, problems) = await env.configStore.current()
        #expect(problems.isEmpty)
        #expect(newsletterDecision(rules) == .classify(ruleID: "vain-kuitit", label: "Lajittelu/Kuitit", alsoMatched: []))
    }

    @Test func invalidRulesKeepTheLastGoodCopy() async throws {
        try env.setRules(receiptsOnly)
        _ = await env.configStore.current()
        try env.setRules(Data(#"{"schema": 1, "rules": [{"id": "x", "enabled": true, "label": "Kuitit", "any": []}]}"#.utf8))
        let (_, rules, problems) = await env.configStore.current()
        #expect(!problems.isEmpty)
        #expect(newsletterDecision(rules) == .classify(ruleID: "vain-kuitit", label: "Lajittelu/Kuitit", alsoMatched: []))
    }

    @Test func invalidRulesAtStartUseTheDefaults() async throws {
        try env.setRules(Data("{\"schema\": 2}".utf8))
        let (_, rules, problems) = await env.configStore.current()
        #expect(!problems.isEmpty)
        #expect(newsletterDecision(rules) == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet",
                                                       alsoMatched: ["kuitit"]))
    }

    @Test func fixingTheFileClearsTheProblem() async throws {
        try env.setRules(Data("{".utf8))
        #expect(!(await env.configStore.current().problems.isEmpty))
        try env.setRules(receiptsOnly)
        #expect(await env.configStore.current().problems.isEmpty)
    }

    @Test func invalidDaemonJSONKeepsTheLastGoodCopy() async throws {
        try env.setConfig(wake: .live, sorting: .live)
        #expect(await env.configStore.current().config.sorting == .live)
        try env.writeFile(Data("{\"wake\": \"sometimes\"}".utf8), to: env.paths.config)
        let (config, _, problems) = await env.configStore.current()
        #expect(config.sorting == .live)
        #expect(!problems.isEmpty)
    }

    @Test func unchangedMTimeIsNotReread() async throws {
        try env.setRules(receiptsOnly)
        _ = await env.configStore.current()
        let stamp = try #require(mtime(env.paths.rules))
        // Same mtime, size and inode (rewritten in place): the store's change stamp is unchanged, so not looked at.
        try Data(String(repeating: "{", count: receiptsOnly.count).utf8).write(to: env.paths.rules)
        try setMTime(env.paths.rules, stamp)
        let (_, rules, problems) = await env.configStore.current()
        #expect(problems.isEmpty)
        #expect(newsletterDecision(rules) == .classify(ruleID: "vain-kuitit", label: "Lajittelu/Kuitit", alsoMatched: []))
    }
}

/// D13 / §13: the LaunchAgent and the embedded Info.plist templates.
@Suite struct PlistTemplateTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func plist(_ name: String, _ substitutions: [String: String]) throws -> [String: Any] {
        var text = try String(contentsOf: Self.root.appendingPathComponent("Resources/Daemon/\(name)"), encoding: .utf8)
        for (key, value) in substitutions { text = text.replacingOccurrences(of: key, with: value) }
        let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        return try #require(object as? [String: Any])
    }

    @Test func launchAgent() throws {
        let p = try plist("fi.seise.mail.daemon.plist.template", [
            "__BIN__": "/Users/x/Library/Application Support/Mak8rMail/bin/mak8r-daemon",
            "__DAEMON_DIR__": "/Users/x/Library/Application Support/Mak8rMail/daemon",
            "__LOGS__": "/Users/x/Library/Logs/Mak8rMail",
        ])
        #expect(p["Label"] as? String == "fi.seise.mail.daemon")
        #expect(p["ProgramArguments"] as? [String] == ["/Users/x/Library/Application Support/Mak8rMail/bin/mak8r-daemon", "run"])
        #expect(p["WorkingDirectory"] as? String == "/Users/x/Library/Application Support/Mak8rMail/daemon")
        #expect(p["RunAtLoad"] as? Bool == true)
        #expect((p["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
        #expect(p["ThrottleInterval"] as? Int == 30)
        #expect(p["ExitTimeOut"] as? Int == 20)
        #expect(p["ProcessType"] as? String == "Standard")
        #expect(p["Umask"] as? Int == 63)                                 // 077
        #expect(p["StandardOutPath"] as? String == "/Users/x/Library/Logs/Mak8rMail/daemon.stdout.log")
        #expect(p["StandardErrorPath"] as? String == "/Users/x/Library/Logs/Mak8rMail/daemon.stderr.log")
        #expect(p["EnvironmentVariables"] == nil)                         // no secret in a plist
    }

    @Test func embeddedInfoPlistHoldsOnlyPlaceholders() throws {
        let p = try plist("daemon-Info.plist.template", [:])
        #expect(p["CFBundleIdentifier"] as? String == "fi.seise.mail.daemon")
        #expect(p["CFBundleName"] as? String == "mak8r-daemon")
        #expect(p["CFBundleVersion"] as? String == "__BUILD__")
        #expect(p["GoogleClientID"] as? String == "__CLIENT_ID__")
        #expect(p["GoogleClientSecret"] as? String == "__CLIENT_SECRET__")
    }

    @Test func makefileDeclaresTheDaemonTargets() throws {
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        let phony = try #require(makefile.split(separator: "\n").first { $0.hasPrefix(".PHONY:") })
        for target in ["daemon", "daemon-install", "daemon-uninstall", "daemon-restart", "daemon-status", "daemon-logs", "daemon-login"] {
            #expect(phony.split(separator: " ").contains(Substring(target)), "\(target)")
        }
    }
}
