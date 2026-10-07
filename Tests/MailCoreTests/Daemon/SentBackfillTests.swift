import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §6.7: the sent-address cache is rebuilt from `in:sent newer_than:730d` (To and Cc, at most 5,000 messages),
/// resumably, before classification starts. Wakes run meanwhile.
@Suite struct SentBackfillTests {
    let env: DaemonEnv

    init() throws {
        env = try DaemonEnv()
        try env.writeToken()
        try env.setConfig(sorting: .live)
    }

    var fake: SyncFakeGmail { env.fake }
    var now: Date { env.clock.now() }
    var phase: String? { env.storedBackfill?["phase"] as? String }

    func sentMessages(_ n: Int) {
        for i in 1...n {
            fake.sendMail("s\(i)", to: ["h\(i)@example.fi"], at: now.addingTimeInterval(-Double(i) * 86_400), inHistory: false)
        }
    }

    @Test func bootstrapBuildsTheCacheFromToAndCc() async throws {
        fake.base.update { $0.sendAs = [SendAsSignature(email: "Alias@Example.fi", html: "")] }
        fake.sendMail("s1", to: ["Virtanen, Matti <Matti.Virtanen@x.fi>"], at: now.addingTimeInterval(-86_400), inHistory: false)
        fake.sendMail("s2", to: [env.email, "alias@example.fi"], cc: ["kalle@x.fi (Kalle)"],
                      at: now.addingTimeInterval(-2 * 86_400), inHistory: false)
        fake.sendMail("ancient", to: ["vanha@x.fi"], at: now.addingTimeInterval(-800 * 86_400), inHistory: false)
        let runner = env.runner()
        await tick(runner, limit: 6) { phase == "done" }
        #expect(phase == "done")
        #expect(fake.calls.first == "profile")
        #expect(fake.calls.contains("list messages in:sent newer_than:730d -"))
        let maxResults = fake.sync.withLock { $0.messageListMaxResults }
        #expect(!maxResults.isEmpty && maxResults.allSatisfy { $0 == 500 })
        #expect(fake.count("message headers s1") == 1)
        #expect(fake.count("message headers s2") == 1)
        #expect(fake.count("message headers ancient") == 0)
        let sent = try #require(env.storedSent)
        #expect(Set(sent.keys) == ["matti.virtanen@x.fi", "kalle@x.fi"])  // me and the send-as alias excluded
    }

    @Test func bootstrapStateComesFromTheProfile() async throws {
        fake.bumpHistory(by: 4_321)
        let h = fake.historyID
        let runner = env.runner()
        await tick(runner, limit: 6) { phase == "done" }
        let state = try #require(env.state())
        let watermark = try #require(state["watermark"] as? [String: Any])
        #expect(watermark["historyId"] as? String == String(h))
        #expect((watermark["coverageStart"] as? String).flatMap(parseISO) == now)
        #expect(state["schema"] as? Int == 1)
        #expect(state["account"] as? String == env.email)
        #expect(Set(state["me"] as? [String] ?? []) == [env.email])
        #expect(env.logText.contains("tila luotu"))
    }

    @Test func classificationWaitsUntilTheCacheIsDone() async throws {
        try env.seedState(watermark: "1000", sentBackfill: "pending")
        sentMessages(3)
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(!fake.calls.contains { $0.hasPrefix("list history") })    // the backfill tick returns early
        #expect(fake.modifies(of: "t1").isEmpty)
        await tick(runner, limit: 6) { phase == "done" }
        let firstHistory = fake.calls.firstIndex { $0.hasPrefix("list history") }
        let lastHeaders = fake.calls.lastIndex { $0.hasPrefix("message headers") }
        _ = await runner.syncTick()
        #expect(fake.historyStarts.first == "1000")                       // the watermark taken before the backfill
        if let firstHistory, let lastHeaders { #expect(lastHeaders < firstHistory) }
        #expect(fake.modifies(of: "t1").count == 1)
    }

    @Test func wakesRunDuringTheBackfill() async throws {
        try env.seedState(watermark: "1000", sentBackfill: "pending")
        sentMessages(2)
        fake.labels.addSnoozedThread("snoozed", wake: "20261005T0800Z")
        let runner = env.runner()
        _ = await runner.syncTick()
        _ = await runner.wakeTick()
        #expect(fake.modifies(of: "snoozed").count == 1)
    }

    @Test func resumesFromTheSavedPageToken() async throws {
        try env.seedState(watermark: "1000", sentBackfill: "pending")
        sentMessages(5)
        fake.update {
            $0.messagePageSize = 2
            $0.messageListErrors["2"] = GmailError.offline                 // page 2 fails once
        }
        await tick(env.runner(), limit: 4) { fake.count("list messages in:sent newer_than:730d 2") >= 1 }
        let saved = try #require(env.storedBackfill)
        #expect(saved["phase"] as? String == "running")
        #expect(saved["pageToken"] as? String == "2")
        #expect(saved["fetched"] as? Int == 2)
        #expect((env.storedSent?.count ?? 0) == 2)                         // saved per page

        await tick(env.runner(), limit: 6) { phase == "done" }               // a restarted process
        #expect(phase == "done")
        #expect(fake.calls.filter { $0 == "list messages in:sent newer_than:730d -" }.count == 1)   // never restarted
        for i in 1...5 { #expect(fake.count("message headers s\(i)") == 1, "s\(i)") }
        #expect(env.storedSent?.count == 5)
    }

    @Test func capsTheNumberOfMessages() async throws {
        try env.seedState(watermark: "1000", sentBackfill: "pending")
        try env.setConfig(sorting: .live) { $0.sentBackfill.maxMessages = 3 }
        sentMessages(5)
        await tick(env.runner(), limit: 6) { phase == "done" }
        #expect(phase == "done")
        #expect(fake.count("message headers ") == 3)
        #expect(fake.count("message headers s1") == 1)                   // newest first
        #expect(fake.count("message headers s5") == 0)
    }

    @Test func honoursTheConfiguredDays() async throws {
        try env.seedState(watermark: "1000", sentBackfill: "pending")
        try env.setConfig(sorting: .live) { $0.sentBackfill.days = 30 }
        sentMessages(1)
        await tick(env.runner(), limit: 6) { phase == "done" }
        #expect(fake.calls.contains("list messages in:sent newer_than:30d -"))
    }

    @Test func pacedByTheSorterBudget() async throws {
        let env = try DaemonEnv(autoAdvance: true)
        try env.writeToken()
        try env.seedState(watermark: "1000", sentBackfill: "pending")
        try env.setConfig(sorting: .live) { $0.sync.unitsPerMinute = 100 }
        for i in 1...10 {
            env.fake.sendMail("s\(i)", to: ["h\(i)@example.fi"], at: env.clock.now().addingTimeInterval(-Double(i) * 60), inHistory: false)
        }
        let start = env.clock.now()
        await tick(env.runner(), limit: 6) { (env.storedBackfill?["phase"] as? String) == "done" }
        // 10 × 20 units at 100 units/min needs at least one more minute.
        #expect(env.clock.now() >= start.addingTimeInterval(60))
        let timed = env.fake.timedCalls.filter { $0.call.hasPrefix("message headers") }
        for (i, first) in timed.enumerated() {
            let window = timed[i...].prefix { $0.at < first.at.addingTimeInterval(60) }
            #expect(SyncFakeGmail.units(window.map(\.call)) <= 100)
        }
    }
}
