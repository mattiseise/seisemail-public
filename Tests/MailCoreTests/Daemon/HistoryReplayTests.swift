import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §6.4 sync tick in live mode over `SyncFakeGmail`: history replay, per-page watermark checkpoint, per-thread
/// failures, idempotent replay and propagation. The watermark is observed as the `startHistoryId` of the next
/// `history.list` call, so no state API is needed.
@Suite struct HistoryReplayTests {
    let env: DaemonEnv
    let uutiskirjeet = "Lajittelu/Uutiskirjeet"
    let kuitit = "Lajittelu/Kuitit"
    let marker = "Lajittelu/Luokiteltu"

    init() throws {
        env = try DaemonEnv()
        try env.writeToken()
        try env.seedState(watermark: "1000")
        try env.setConfig(sorting: .live)
    }

    var fake: SyncFakeGmail { env.fake }

    // MARK: One page

    @Test func onePageClassifiesMatchesAndLeavesUnmatchedAlone() async throws {
        env.newsletter("t1")
        fake.deliver("t2", from: "GitHub <noreply@github.com>", subject: "CI epäonnistui")
        fake.deliver("t3", from: "Tuntematon <tuntematon@example.fi>")
        _ = await env.runner().syncTick()
        #expect(fake.historyStarts.first == "1000")
        #expect(fake.labelNames(of: "t1").isSuperset(of: [uutiskirjeet, marker]))
        #expect(fake.labelNames(of: "t2").isSuperset(of: ["Lajittelu/Ilmoitukset", marker]))
        #expect(fake.labelNames(of: "t3") == ["INBOX", "UNREAD"])          // D4: unmatched gets no marker
        #expect(fake.modifies(of: "t1").count == 1)
        #expect(fake.modifies(of: "t2").count == 1)
        #expect(fake.modifies(of: "t3").isEmpty)
        #expect(fake.writes.allSatisfy { !$0.hasPrefix("modify") || $0.hasSuffix(" -") })   // add only
    }

    @Test func liveStackCreatesRuleLabelsShownAndTheMarkerHidden() async throws {
        _ = await env.runner().syncTick()
        #expect(fake.labels.visibility(ofLabelNamed: marker) == .hidden)
        for name in [uutiskirjeet, kuitit, "Lajittelu/Ilmoitukset", "Lajittelu/Ihmiset"] {
            #expect(fake.labels.visibility(ofLabelNamed: name) == .shown, "\(name)")
        }
        #expect(fake.labels.labelID("Lajittelu/Vaatii toimenpidettä") == nil)     // never created by the daemon
        #expect(fake.writes.allSatisfy { !$0.hasPrefix("label delete") })
    }

    @Test func eachThreadIsReadOnceFreshPerTick() async throws {
        fake.deliver("t1")
        fake.deliver("t1", subject: "Re: Hei")
        _ = await env.runner().syncTick()
        #expect(fake.count("thread headers t1") == 1)                      // grouped by thread
    }

    @Test func draftsSpamTrashAndChatHintsAreNotRead() async throws {
        fake.deliver("d1", labels: ["DRAFT"])
        fake.deliver("s1", labels: ["SPAM"])
        fake.deliver("x1", labels: ["TRASH"])
        fake.deliver("c1", labels: ["CHAT"])
        env.newsletter("t1")
        _ = await env.runner().syncTick()
        for id in ["d1", "s1", "x1", "c1"] {
            #expect(fake.count("thread headers \(id)") == 0, "\(id)")
        }
        #expect(fake.modifies(of: "t1").count == 1)
    }

    @Test func decisionsAreLoggedInLiveModeToo() async throws {
        env.newsletter("t1")
        _ = await env.runner().syncTick()
        let line = try #require(env.decisionLines.first { $0["thread"] as? String == "t1" })
        #expect(line["mode"] as? String == "live")
        #expect(line["decision"] as? String == "classify")
        #expect(line["rule"] as? String == "uutiskirjeet")
        #expect(line["label"] as? String == uutiskirjeet)
        #expect(line["account"] as? String == env.email)
        #expect(line["msg"] as? String == "t1-m1")
    }

    // MARK: Idempotent replay

    @Test func sameHistoryTwiceMakesNoExtraModify() async throws {
        env.newsletter("t1")
        fake.deliver("t2", from: "GitHub <noreply@github.com>")
        _ = await env.runner().syncTick()
        let writes = fake.writes.count
        try env.seedState(watermark: "1000")                               // the watermark update was lost
        _ = await env.runner().syncTick()
        #expect(fake.writes.count == writes)
        #expect(fake.count("thread headers t1") == 2)
    }

    @Test func crashAfterModifyBeforeSaveReplaysWithoutWrites() async throws {
        let u = fake.labels.addLabel(uutiskirjeet)
        let m = fake.labels.addLabel(marker, visibility: .hidden)
        env.newsletter("t1")
        fake.labels.apply([u, m], to: "t1")                                // the modify landed, the save did not
        _ = await env.runner().syncTick()
        #expect(fake.modifies(of: "t1").isEmpty)
        #expect(fake.count("thread headers t1") == 1)
    }

    // MARK: Watermark checkpoints

    @Test func twoPagesCheckpointLastRecordThenHistoryID() async throws {
        fake.update { $0.historyPageSize = 2 }
        env.newsletter("a")                                                // record 1001
        env.newsletter("b")                                                // record 1002
        env.newsletter("c")                                                // record 1003
        fake.update { $0.threadHeaderErrors["c"] = [GmailError.http(500, "backend")] }
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "a").count == 1)
        #expect(fake.modifies(of: "b").count == 1)
        #expect(fake.modifies(of: "c").isEmpty)

        let before = fake.historyStarts.count
        let mailbox = fake.historyID                                       // reported by tick 2's last page
        _ = await runner.syncTick()
        #expect(fake.historyStarts[before] == "1002")                      // page 1 checkpoint: its lastRecordID
        #expect(fake.modifies(of: "c").count == 1)
        #expect(fake.modifies(of: "a").count == 1)                          // page 1 is not replayed

        _ = await runner.syncTick()
        #expect(fake.historyStarts.last == String(mailbox))                 // last page: the mailbox historyId
    }

    @Test func emptyHistoryAdvancesToTheMailboxHistoryID() async throws {
        fake.bumpHistory(by: 7)                                            // read/unread toggles elsewhere
        let runner = env.runner()
        _ = await runner.syncTick()
        _ = await runner.syncTick()
        #expect(fake.historyStarts == ["1000", "1007"])
    }

    @Test func rateLimitedMidPageKeepsTheWatermark() async throws {
        env.newsletter("a")
        env.newsletter("b")
        fake.update { $0.threadHeaderErrors["b"] = [GmailError.rateLimited] }
        let runner = env.runner()
        _ = await runner.syncTick()
        _ = await runner.syncTick()
        #expect(Array(fake.historyStarts.prefix(2)) == ["1000", "1000"])
        #expect(fake.modifies(of: "a").count == 1)                          // the replay of a writes nothing
        #expect(fake.modifies(of: "b").count == 1)
    }

    @Test func offlineHistoryKeepsTheWatermark() async throws {
        env.newsletter("a")
        fake.update { $0.historyErrors = [GmailError.offline] }
        let runner = env.runner()
        _ = await runner.syncTick()
        _ = await runner.syncTick()
        #expect(fake.historyStarts == ["1000", "1000"])
        #expect(fake.modifies(of: "a").count == 1)
    }

    @Test func threadFailingThreeTicksIsSkippedAndTheWatermarkAdvances() async throws {
        env.newsletter("a")
        env.newsletter("c")
        fake.update { $0.failingThreadHeaders["c"] = GmailError.http(500, "backend") }
        let runner = env.runner()
        _ = await runner.syncTick()
        _ = await runner.syncTick()
        let mailbox = fake.historyID
        _ = await runner.syncTick()                                        // third failure: skipped
        _ = await runner.syncTick()
        #expect(fake.historyStarts == ["1000", "1000", "1000", String(mailbox)])
        #expect(fake.count("thread headers c") == 3)
        #expect(fake.modifies(of: "a").count == 1)
        #expect(env.logText.contains("ohitettu"))
        #expect(env.logText.contains("ERROR"))
    }

    @Test func goneThreadIsSkippedWithoutStoppingThePage() async throws {
        env.newsletter("gone")
        fake.removeThread("gone")
        env.newsletter("t2")
        let runner = env.runner()
        let mailbox = fake.historyID
        _ = await runner.syncTick()
        _ = await runner.syncTick()
        #expect(fake.historyStarts == ["1000", String(mailbox)])
        #expect(fake.count("thread headers gone") == 1)
        #expect(fake.modifies(of: "t2").count == 1)
    }

    @Test func twoThreadsFailingOutOfStepStillLetTheWatermarkMove() async throws {
        env.newsletter("a")
        fake.update { $0.failingThreadHeaders["a"] = GmailError.http(500, "backend") }
        let runner = env.runner()
        _ = await runner.syncTick()                                        // a: 1st failure
        env.newsletter("b")                                                // joins the same (last) page a tick later
        fake.update { $0.failingThreadHeaders["b"] = GmailError.http(500, "backend") }
        for _ in 0..<5 { _ = await runner.syncTick() }
        #expect(fake.historyStarts.contains { $0 != "1000" })              // given up threads no longer hold the page
        #expect(fake.count("thread headers a") == 3)                       // given up: not read again for this page
        #expect(fake.count("thread headers b") == 3)
        #expect(fake.historyStarts.last == String(fake.historyID))
    }

    // MARK: Sent cache within a batch

    @Test func sentAndIncomingInOneBatchClassifiesIhmiset() async throws {
        fake.sendMail("s1", to: ["Kalle <Kalle@Example.FI>"])
        fake.deliver("t2", from: "Kalle Koski <kalle@example.fi>")
        _ = await env.runner().syncTick()
        #expect(fake.labelNames(of: "t2").isSuperset(of: ["Lajittelu/Ihmiset", marker]))
        #expect(fake.modifies(of: "s1").isEmpty)                           // SENT never decides
        #expect(env.storedSent?["kalle@example.fi"] != nil)                // sent changes are saved at once
        #expect(env.storedSent?[env.email] == nil)
    }

    @Test func ccRecipientsCountAndMeIsExcluded() async throws {
        fake.sendMail("s1", to: ["\(env.email)"], cc: ["Liisa <liisa@example.fi>"])
        fake.deliver("t2", from: "liisa@example.fi")
        _ = await env.runner().syncTick()
        #expect(fake.labelNames(of: "t2").contains("Lajittelu/Ihmiset"))
        #expect(env.storedSent?[env.email] == nil)
    }

    // MARK: Manual always wins

    @Test func manualChangeUutiskirjeetToKuititPropagatesKuitit() async throws {
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()
        let u = try #require(env.labelID(uutiskirjeet))
        let k = try #require(env.labelID(kuitit))
        let classified = fake.modifies(of: "t1").count                     // the first classification added U
        fake.labels.strip([u], from: "t1")
        fake.labels.apply([k], to: "t1")
        env.newsletter("t1")                                               // t1-m2 arrives
        _ = await runner.syncTick()
        #expect(fake.labelNames(ofMessage: "t1-m2").isSuperset(of: [kuitit, marker]))
        #expect(!fake.labelNames(of: "t1").contains(uutiskirjeet))
        let later = fake.modifies(of: "t1").dropFirst(classified)
        #expect(!later.isEmpty)
        #expect(later.allSatisfy { !$0.split(whereSeparator: { " +-,".contains($0) }).contains(Substring(u)) })
    }

    @Test func removedLabelNeverComesBack() async throws {
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()
        let u = try #require(env.labelID(uutiskirjeet))
        fake.labels.strip([u], from: "t1")                                 // marker stays
        env.newsletter("t1")
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "t1").count == 1)
        #expect(!fake.labelNames(of: "t1").contains(uutiskirjeet))
        let line = env.decisionLines.last { $0["thread"] as? String == "t1" }
        #expect(line?["decision"] as? String == "manualKept")
    }

    /// Conventions §1: the thread is read fresh just before the write. A write for an earlier thread of the
    /// same page must not make a later thread's write rest on an older read.
    @Test func relabelDuringTheTickBeforeTheThreadsWriteWins() async throws {
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()                                        // t1: Uutiskirjeet + marker
        let u = try #require(env.labelID(uutiskirjeet))
        let k = try #require(env.labelID(kuitit))
        fake.deliver("t2", from: "GitHub <noreply@github.com>", subject: "CI epäonnistui")   // first on the page
        env.newsletter("t1")                                               // t1-m2
        fake.labels.updateLabels { s in
            s.beforeModify = { labels, id, _ in
                guard id == "t2" else { return }
                labels.strip([u], from: "t1")                              // Matti: Uutiskirjeet → Kuitit
                labels.apply([k], to: "t1")
            }
        }
        _ = await runner.syncTick()
        #expect(!fake.labelNames(of: "t1").contains(uutiskirjeet))
        #expect(fake.labelNames(ofMessage: "t1-m2").isSuperset(of: [kuitit, marker]))
    }

    @Test func aBudgetWaitBetweenReadAndWriteRereadsTheThread() async throws {
        let env = try DaemonEnv()
        try env.writeToken()
        try env.seedState(watermark: "1000")
        try env.setConfig(sorting: .live) { $0.sync.unitsPerMinute = 100 }
        let fake = env.fake
        env.newsletter("t1")
        let runner = env.runner()
        env.clock.setAutoAdvance(true)
        _ = await runner.syncTick()                                        // t1: Uutiskirjeet + marker
        env.clock.setAutoAdvance(false)
        env.clock.advance(by: 120)                                         // an empty budget window
        let u = try #require(env.labelID(uutiskirjeet))
        let k = try #require(env.labelID(kuitit))
        fake.deliver("t0", from: "GitHub <noreply@github.com>", subject: "CI epäonnistui")
        env.newsletter("t1")
        // 2 + 40 + 10 (t0) + 40 (t1) = 92: t1's write waits for the window.
        let task = Task { await runner.syncTick() }
        #expect(await eventually { env.clock.sleeperCount == 1 })
        fake.labels.strip([u], from: "t1")                                 // Matti relabels during the wait
        fake.labels.apply([k], to: "t1")
        env.clock.advance(by: 120)
        _ = await task.value
        #expect(!fake.labelNames(of: "t1").contains(uutiskirjeet))
        #expect(fake.labelNames(ofMessage: "t1-m2").isSuperset(of: [kuitit, marker]))
    }

    @Test func manualOverrideSurvivesALostStateFile() async throws {
        env.newsletter("t1")
        _ = await env.runner().syncTick()
        let u = try #require(env.labelID(uutiskirjeet))
        fake.labels.strip([u], from: "t1")                                 // marker stays
        let state = env.paths.state(env.email)
        try FileManager.default.removeItem(at: state)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: state.path + ".bak"))
        let runner = env.runner()                                          // bootstrap + sent backfill
        await tick(runner, limit: 10) { env.storedBackfill?["phase"] as? String == "done" }
        #expect(env.storedBackfill?["phase"] as? String == "done")
        env.newsletter("t1")
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "t1").count == 1)                        // only the first classification
        #expect(!fake.labelNames(of: "t1").contains(uutiskirjeet))
        let line = env.decisionLines.last { $0["thread"] as? String == "t1" }
        #expect(line?["decision"] as? String == "manualKept")
        env.clock.advance(by: 31 * 60)                                     // a sweep over the same mailbox
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "t1").count == 1)
    }

    @Test func renamedLabelIsSeenAfterTheLabelRefreshInterval() async throws {
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()
        let u = try #require(env.labelID(uutiskirjeet))
        fake.labels.renameLabel(u, to: "Uutiskirjeet")                     // Matti renames it; the ID stays
        env.clock.advance(by: AccountRunner.labelRefreshInterval)
        env.newsletter("t2")
        _ = await runner.syncTick()
        #expect(fake.labelNames(of: "t2").isSuperset(of: [uutiskirjeet, marker]))   // a new Lajittelu/Uutiskirjeet
        #expect(!fake.labelNames(of: "t2").contains("Uutiskirjeet"))
    }

    // MARK: Mode changes mid-tick

    @Test func switchingSortingOffMidTickStopsTheWritesAtOnce() async throws {
        env.newsletter("t1")
        env.newsletter("t2")
        env.newsletter("t3")
        let env = self.env
        fake.labels.updateLabels { s in
            s.beforeModify = { _, _, call in if call == 1 { try? env.setConfig(sorting: .off) } }
        }
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(fake.count("modify ") == 1)                                // `mode sorting off` stops the rest
        #expect(await runner.syncTick().result == .skipped("off"))
        fake.labels.updateLabels { $0.beforeModify = nil }
        try env.setConfig(sorting: .live)
        _ = await runner.syncTick()
        for id in ["t1", "t2", "t3"] {
            #expect(fake.labelNames(of: id).isSuperset(of: [uutiskirjeet, marker]), "\(id)")
            #expect(fake.modifies(of: id).count == 1, "\(id)")             // the watermark stayed: nothing lost
        }
    }

    @Test func switchingToShadowMidTickSendsNoMoreLiveWrites() async throws {
        env.newsletter("t1")
        env.newsletter("t2")
        let env = self.env
        fake.labels.updateLabels { s in
            s.beforeModify = { _, _, call in if call == 1 { try? env.setConfig(sorting: .shadow) } }
        }
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(fake.count("modify ") == 1)
        _ = await runner.syncTick()                                        // the shadow stack takes over
        #expect(fake.count("modify ") == 1)
        #expect(env.shadowWrites.contains { if case .modify(let t, _, _) = $0 { t == "t2" } else { false } })
    }

    @Test func unmatchedThreadIsReevaluatedAtItsNextMessage() async throws {
        fake.deliver("t1", from: "Tuntematon <tuntematon@example.fi>")
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "t1").isEmpty)
        env.newsletter("t1")
        _ = await runner.syncTick()
        #expect(fake.labelNames(of: "t1").isSuperset(of: [uutiskirjeet, marker]))
    }

    @Test func customSortingLabelPropagates() async throws {
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()
        let own = fake.labels.addLabel("Lajittelu/Kerho")
        fake.labels.apply([own], to: "t1")
        fake.deliver("t1", subject: "Re: Viikon uutiset")
        _ = await runner.syncTick()
        #expect(fake.labelNames(ofMessage: "t1-m2").isSuperset(of: ["Lajittelu/Kerho", uutiskirjeet, marker]))
    }

    // MARK: Pacing

    @Test func budgetSleepNeverDropsWork() async throws {
        let env = try DaemonEnv(autoAdvance: true)
        try env.writeToken()
        try env.seedState(watermark: "1000")
        try env.setConfig(sorting: .live) { $0.sync.unitsPerMinute = 100 }
        for i in 1...5 { env.newsletter("t\(i)") }
        let start = env.clock.now()
        _ = await env.runner().syncTick()
        for i in 1...5 {
            #expect(env.fake.labelNames(of: "t\(i)").contains(uutiskirjeet), "t\(i)")
        }
        #expect(env.clock.now() >= start.addingTimeInterval(120))         // 250 units at 100/min
    }
}
