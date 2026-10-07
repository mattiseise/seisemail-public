import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §6.6 inbox scans: the 404 resync, `backfill` requests and the 30-minute sweep. All share the decision table.
@Suite struct InboxScanTests {
    let env: DaemonEnv
    let marker = "Lajittelu/Luokiteltu"

    init() throws {
        env = try DaemonEnv()
        try env.writeToken()
    }

    var fake: SyncFakeGmail { env.fake }
    var now: Date { env.clock.now() }

    func index(_ prefix: String) -> Int? { fake.calls.firstIndex { $0.hasPrefix(prefix) } }

    // MARK: Resync (history 404)

    @Test func historyExpiredRunsABoundedResync() async throws {
        let advancedAt = now.addingTimeInterval(-2 * 86_400)
        try env.seedState(watermark: "1000", advancedAt: advancedAt)
        try env.setConfig(sorting: .live)
        let cutoff = epoch(advancedAt.addingTimeInterval(-3_600))
        fake.sendMail("s1", to: ["Kalle <kalle@example.fi>"], at: now.addingTimeInterval(-86_400), inHistory: false)
        fake.deliver("t1", from: "Kalle Koski <kalle@example.fi>", at: now.addingTimeInterval(-80_000), inHistory: false)
        fake.deliver("old", from: "GitHub <noreply@github.com>", at: advancedAt.addingTimeInterval(-7_200), inHistory: false)
        fake.bumpHistory(by: 1_000)
        fake.update { $0.expiredBelow = 1_500 }
        let h0 = fake.historyID
        let runner = env.runner()
        await tick(runner, limit: 6) { fake.historyStarts.contains(String(h0)) }

        let profile = try #require(index("profile"))
        let sent = try #require(index("list messages in:sent after:\(cutoff) "))
        let inbox = try #require(index("list in:inbox after:\(cutoff) "))
        #expect(profile < sent)                                           // H0 is read first
        #expect(sent < inbox)                                             // sent cache before deciding
        #expect(fake.count("message headers s1") == 1)
        #expect(fake.count("thread headers old") == 0)                    // before the cutoff
        #expect(fake.labelNames(of: "t1").isSuperset(of: ["Lajittelu/Ihmiset", marker]))
        #expect(fake.historyStarts.first == "1000")
        #expect(fake.historyStarts.contains(String(h0)))                  // W = H0 afterwards
        #expect(env.storedSent?["kalle@example.fi"] != nil)
    }

    @Test func resyncLooksBackAtMost30Days() async throws {
        try env.seedState(watermark: "1000", advancedAt: now.addingTimeInterval(-60 * 86_400))
        try env.setConfig(sorting: .live)
        fake.update { $0.expiredBelow = 1_500 }
        fake.bumpHistory(by: 1_000)
        let h0 = fake.historyID
        let cutoff = epoch(now.addingTimeInterval(-30 * 86_400))
        await tick(env.runner(), limit: 6) { fake.historyStarts.contains(String(h0)) }
        #expect(index("list messages in:sent after:\(cutoff) ") != nil)
        #expect(index("list in:inbox after:\(cutoff) ") != nil)
    }

    @Test func resyncHonoursResyncMaxDays() async throws {
        try env.seedState(watermark: "1000", advancedAt: now.addingTimeInterval(-60 * 86_400))
        try env.setConfig(sorting: .live) { $0.sync.resyncMaxDays = 7 }
        fake.update { $0.expiredBelow = 1_500 }
        fake.bumpHistory(by: 1_000)
        let h0 = fake.historyID
        await tick(env.runner(), limit: 6) { fake.historyStarts.contains(String(h0)) }
        #expect(index("list in:inbox after:\(epoch(now.addingTimeInterval(-7 * 86_400))) ") != nil)
    }

    @Test func resyncInShadowWritesNothing() async throws {
        try env.seedState(watermark: "1000", advancedAt: now.addingTimeInterval(-86_400))
        try env.setConfig(sorting: .shadow)
        env.newsletter("t1", at: now.addingTimeInterval(-3_600))
        fake.update { $0.expiredBelow = 1_500 }
        fake.bumpHistory(by: 1_000)
        let h0 = fake.historyID
        await tick(env.runner(), limit: 6) { fake.historyStarts.contains(String(h0)) }
        #expect(fake.writes.isEmpty)
        #expect(env.decisionLines.contains { $0["thread"] as? String == "t1" && $0["mode"] as? String == "shadow" })
    }

    @Test func resyncSurvivesARestart() async throws {
        // An offline answer on page 2 of the inbox listing ends the tick mid-scan; a new process continues from
        // the saved page token instead of losing (or repeating) the scan.
        try env.seedState(watermark: "1000", advancedAt: now.addingTimeInterval(-86_400))
        try env.setConfig(sorting: .live)
        for i in 1...3 { env.newsletter("t\(i)", at: now.addingTimeInterval(-Double(i) * 600)) }   // t1 newest
        fake.update {
            $0.expiredBelow = 1_500
            $0.threadPageSize = 1
            $0.threadHeaderErrors["t2"] = [GmailError.offline]
        }
        fake.bumpHistory(by: 1_000)
        let h0 = fake.historyID
        await tick(env.runner(), limit: 6) { fake.count("thread headers t2") >= 1 }
        let scan = try #require(env.state()?["scan"] as? [String: Any])
        #expect(scan["kind"] as? String == "resync")
        #expect(scan["h0"] as? String == String(h0))
        #expect(scan["pageToken"] as? String == "1")
        await tick(env.runner(), limit: 8) { fake.historyStarts.contains(String(h0)) }
        for i in 1...3 { #expect(fake.labelNames(of: "t\(i)").contains("Lajittelu/Uutiskirjeet"), "t\(i)") }
        #expect(fake.count("thread headers t1") == 1)                     // page 1 is not scanned again
        #expect(fake.historyStarts.contains(String(h0)))
    }

    // MARK: Backfill requests

    func oldNewsletters(_ n: Int) {
        for i in 1...n {
            fake.deliver("b\(i)", from: "Uutiset <uutiset@lehti.fi>", headers: ["List-Id": "<lehti>"],
                         at: now.addingTimeInterval(-Double(i) * 3_600), inHistory: false)
        }
    }

    @Test func backfillRunsInShadowModeAndDeletesTheRequest() async throws {
        try env.seedState(watermark: "1000")
        try env.setConfig(sorting: .shadow)
        oldNewsletters(3)
        let since = now.addingTimeInterval(-3 * 86_400)
        let request = try env.requestBackfill(since: since)
        await tick(env.runner(), limit: 6) { !FileManager.default.fileExists(atPath: request.path) }
        #expect(!FileManager.default.fileExists(atPath: request.path))
        #expect(index("list in:inbox after:\(epoch(since)) ") != nil)
        #expect(fake.writes.isEmpty)
        for i in 1...3 {
            #expect(env.decisionLines.contains { $0["thread"] as? String == "b\(i)" && $0["mode"] as? String == "shadow" }, "b\(i)")
        }
    }

    @Test func backfillRunsInLiveModeAndLabels() async throws {
        try env.seedState(watermark: "1000")
        try env.setConfig(sorting: .live)
        oldNewsletters(3)
        let request = try env.requestBackfill(since: now.addingTimeInterval(-3 * 86_400))
        await tick(env.runner(), limit: 6) { !FileManager.default.fileExists(atPath: request.path) }
        for i in 1...3 {
            #expect(fake.labelNames(of: "b\(i)").isSuperset(of: ["Lajittelu/Uutiskirjeet", marker]), "b\(i)")
        }
    }

    @Test func backfillLeavesClassifiedAndManualThreadsAlone() async throws {
        try env.seedState(watermark: "1000")
        try env.setConfig(sorting: .live)
        oldNewsletters(2)
        let m = fake.labels.addLabel(marker, visibility: .hidden)
        fake.labels.apply([m], to: "b1")                                   // Matti removed its label earlier
        let request = try env.requestBackfill(since: now.addingTimeInterval(-3 * 86_400))
        await tick(env.runner(), limit: 6) { !FileManager.default.fileExists(atPath: request.path) }
        #expect(fake.modifies(of: "b1").isEmpty)
        #expect(fake.modifies(of: "b2").count == 1)
    }

    @Test func backfillResumesFromTheSavedPageToken() async throws {
        let cutoff = now.addingTimeInterval(-3 * 86_400)
        let request = try env.requestBackfill(since: cutoff)
        try env.seedState(watermark: "1000", scan: ["kind": "backfill", "cutoff": iso(cutoff), "pageToken": "1",
                                                    "requestFile": request.lastPathComponent])
        try env.setConfig(sorting: .live)
        oldNewsletters(3)
        await tick(env.runner(), limit: 6) { !FileManager.default.fileExists(atPath: request.path) }
        #expect(index("list in:inbox after:\(epoch(cutoff)) 1") != nil)
        #expect(index("list in:inbox after:\(epoch(cutoff)) -") == nil)
        #expect(fake.count("thread headers b1") == 0)                     // the newest was on the finished page
    }

    // MARK: Sweep

    /// Mail that history has not listed yet while `historyId` already moved past it.
    func lagged(_ n: Int, minutesAgo: Double = 10) {
        fake.update { $0.lagAfter = $0.historyID }
        for i in 1...n { env.newsletter("lag\(i)", at: now.addingTimeInterval(-minutesAgo * 60 - Double(i))) }
    }

    func sweepQuery(after date: Date) -> String {
        "list in:inbox after:\(epoch(date)) -label:lajittelu-luokiteltu "
    }

    @Test func sweepCatchesHistoryLagInLiveMode() async throws {
        let coverage = now.addingTimeInterval(-3_600)
        try env.seedState(watermark: "1000", coverageStart: coverage, sweepAt: now.addingTimeInterval(-31 * 60))
        try env.setConfig(sorting: .live)
        lagged(3)
        _ = await env.runner().syncTick()
        #expect(index(sweepQuery(after: coverage)) != nil)                // window starts at coverageStart
        for i in 1...3 {
            #expect(fake.labelNames(of: "lag\(i)").isSuperset(of: ["Lajittelu/Uutiskirjeet", marker]), "lag\(i)")
        }
    }

    @Test func sweepWindowIsAtMostTwoHours() async throws {
        try env.seedState(watermark: "1000", coverageStart: now.addingTimeInterval(-5 * 3_600),
                          sweepAt: now.addingTimeInterval(-31 * 60))
        try env.setConfig(sorting: .live)
        lagged(1)
        fake.deliver("older", from: "Uutiset <u@lehti.fi>", headers: ["List-Id": "<x>"],
                     at: now.addingTimeInterval(-3 * 3_600), inHistory: false)
        _ = await env.runner().syncTick()
        #expect(index(sweepQuery(after: now.addingTimeInterval(-2 * 3_600))) != nil)
        #expect(fake.count("thread headers older") == 0)
    }

    @Test func sweepReadsAtMost25Threads() async throws {
        try env.seedState(watermark: "1000", sweepAt: now.addingTimeInterval(-31 * 60))
        try env.setConfig(sorting: .live)
        lagged(30)
        _ = await env.runner().syncTick()
        let reads = fake.calls.filter { $0.hasPrefix("thread headers lag") }.count
        #expect(reads >= 1)
        #expect(reads <= 25)
    }

    @Test func sweepIsLiveOnly() async throws {
        try env.seedState(watermark: "1000", sweepAt: now.addingTimeInterval(-31 * 60))
        try env.setConfig(sorting: .shadow)
        lagged(2)
        _ = await env.runner().syncTick()
        #expect(!fake.calls.contains { $0.contains("-label:lajittelu-luokiteltu") })
    }

    @Test func sweepNeedsTheMarkerLabel() async throws {
        try env.seedState(watermark: "1000", sweepAt: now.addingTimeInterval(-31 * 60))
        try env.setConfig(sorting: .live)
        fake.labels.updateLabels { $0.createErrors["lajittelu/luokiteltu"] = 400 }    // reserved: never confirmed
        lagged(2)
        _ = await env.runner().syncTick()
        #expect(!fake.calls.contains { $0.contains("-label:lajittelu-luokiteltu") })
    }

    @Test func sweepRunsEverySweepMinutes() async throws {
        try env.seedState(watermark: "1000", sweepAt: now.addingTimeInterval(-5 * 60))
        try env.setConfig(sorting: .live)
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(!fake.calls.contains { $0.contains("-label:lajittelu-luokiteltu") })
        env.clock.advance(by: 26 * 60)
        _ = await runner.syncTick()
        #expect(fake.calls.filter { $0.contains("-label:lajittelu-luokiteltu") }.count == 1)
        env.clock.advance(by: 60)
        _ = await runner.syncTick()
        #expect(fake.calls.filter { $0.contains("-label:lajittelu-luokiteltu") }.count == 1)
    }

    @Test func unmatchedThreadIsCountedOnceAcrossSweeps() async throws {
        try env.seedState(watermark: "1000", coverageStart: now.addingTimeInterval(-3 * 3_600), sweepAt: now)
        try env.setConfig(sorting: .live)
        env.newsletter("n1")                                               // classified: the marker exists
        fake.deliver("t1", from: "Tuntematon <tuntematon@example.fi>")
        let runner = env.runner()
        _ = await runner.syncTick()
        for _ in 0..<3 {
            env.clock.advance(by: 31 * 60)
            _ = await runner.syncTick()
        }
        #expect(fake.calls.filter { $0.contains("-label:lajittelu-luokiteltu") }.count == 3)
        #expect(env.decisionLines.filter { $0["thread"] as? String == "t1" }.count == 1)
        #expect(await runner.status().today.unmatched == 1)
        #expect(fake.modifies(of: "t1").isEmpty)
    }

    @Test func requestFilesBelongOnlyToTheirOwnAccount() throws {
        let dir = env.paths.requests
        for name in ["backfill-matti@example.fi-20261005090030.json", "backfill-matti@example.fi-x-20261005090030.json",
                     "note-matti@example.fi-x-20261005090030.json", "note-matti@example.fi-20261005090031.json"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
        #expect(BackfillRequest.pending(account: "matti@example.fi", in: dir).map(\.lastPathComponent)
                == ["backfill-matti@example.fi-20261005090030.json"])
        #expect(NoteRequest.pending(account: "matti@example.fi", in: dir).map(\.lastPathComponent)
                == ["note-matti@example.fi-20261005090031.json"])
        #expect(BackfillRequest.pending(account: "matti@example.fi-x", in: dir).count == 1)
    }
}
