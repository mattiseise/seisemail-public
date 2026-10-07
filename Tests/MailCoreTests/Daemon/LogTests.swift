import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §11.1–§11.2: untrusted text is sanitised; tokens, subjects and sender addresses never reach `daemon.log`.
@Suite struct SanitizeTests {
    @Test func plainTextIsKept() {
        #expect(Sanitize.field("Kuitti Applelta – tilaus 4.10.") == "Kuitti Applelta – tilaus 4.10.")
    }

    @Test func controlAndFormatCharactersAreStripped() {
        let dirty = "a\u{0000}b\u{0007}c\u{001B}[31md\u{0085}e\u{009F}f\u{00AD}g\u{200B}h\u{202E}i\u{2066}j\u{FEFF}k\nl\tm"
        let clean = Sanitize.field(dirty)
        #expect(!clean.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
        #expect(clean.contains("a") && clean.contains("m"))
    }

    @Test func atMost120Characters() {
        #expect(Sanitize.field(String(repeating: "ä", count: 500)).count <= 120)
        #expect(Sanitize.field(String(repeating: "x", count: 120)).count == 120)
    }

    @Test func quotesCannotEndTheField() {
        let clean = Sanitize.field("a\"b")
        var previous: Character?
        for c in clean {
            if c == "\"" { #expect(previous == "\\") }
            previous = c
        }
    }
}

@Suite struct LogTests {
    @Test func secretsSubjectsAndSendersNeverReachTheDaemonLog() async throws {
        let env = try DaemonEnv()
        try env.writeToken("1//refresh-SECRET-0123456789")
        try env.seedState(watermark: "1000")
        try env.setConfig(wake: .live, sorting: .live)
        env.fake.deliver("t1", from: "Salainen Lähettäjä <salainen.lahettaja@lehti.fi>", subject: "Hyvin salainen aihe",
                         headers: ["List-Unsubscribe": "<mailto:x>"])
        env.fake.labels.addSnoozedThread("snoozed", wake: "20261005T0800Z")
        let runner = env.runner()
        _ = await runner.wakeTick()
        _ = await runner.syncTick()
        try env.writeToken("1//refresh-SECRET-new-login")
        _ = await runner.syncTick()
        let log = env.logText
        #expect(!log.isEmpty)
        #expect(!log.contains("SECRET"))
        #expect(!log.contains("refresh-"))
        #expect(!log.contains("Hyvin salainen aihe"))
        #expect(!log.contains("salainen.lahettaja@lehti.fi"))
        #expect(log.contains(fingerprint("1//refresh-SECRET-new-login")) || !log.contains("fingerprint"))
        let decisions = try String(contentsOf: env.decisionsURL, encoding: .utf8)
        #expect(!decisions.contains("SECRET"))
        #expect(posixMode(env.logURL) == 0o600)
        #expect(posixMode(env.decisionsURL) == 0o600)
    }

    @Test func logLinesCarryAnOffsetTimestampAndALevel() async throws {
        let env = try DaemonEnv()
        try env.writeToken()
        try env.seedState(watermark: "1000")
        env.fake.labels.addSnoozedThread("snoozed", wake: "20261005T0800Z")
        _ = await env.runner().wakeTick()
        let line = try #require(env.logText.split(separator: "\n").first { $0.contains("woken=1") })
        // 2026-10-06T09:14:02.041+03:00 INFO  … wake woken=1 …
        #expect(line.prefixMatch(of: #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?([+-]\d{2}:\d{2}|Z) /#) != nil)
        #expect(line.contains(" INFO ") || line.contains(" NOTICE "))
    }
}
