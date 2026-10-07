import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §12: per-tick costs (units counted from the fake's calls with Gmail's prices), the sorter's 2,000/min pacing
/// that keeps ≥ 1,000/min for wakes, `MinuteBudget`, `ProbeTransport` and `GmailQuotaPrice`.
@Suite struct QuotaBudgetTests {
    let env: DaemonEnv

    init() throws {
        env = try DaemonEnv()
        try env.writeToken()
        try env.seedState(watermark: "1000")
        try env.setConfig(wake: .live, sorting: .live)
    }

    var fake: SyncFakeGmail { env.fake }

    /// One minute with both loops so the stack and its labels exist, then a clean call log.
    func warmUp(_ runner: AccountRunner) async {
        fake.labels.addLabel("Torkku")                                    // the wake listing runs, as on the account
        _ = await runner.wakeTick()
        _ = await runner.syncTick()
        env.clock.advance(by: 60)
        fake.resetCalls()
    }

    @Test func idleMinuteCosts13Units() async throws {
        let runner = env.runner()
        await warmUp(runner)
        _ = await runner.wakeTick()
        let wake = fake.calls
        _ = await runner.syncTick()
        let sync = Array(fake.calls.dropFirst(wake.count))
        #expect(SyncFakeGmail.units(wake) == 11, "\(wake)")              // labels.list + threads.list by label
        #expect(SyncFakeGmail.units(sync) == 2, "\(sync)")               // history.list
        #expect(SyncFakeGmail.units(fake.calls) == 13)
    }

    @Test func classifiedThreadCosts50() async throws {
        let runner = env.runner()
        await warmUp(runner)
        env.newsletter("t1")
        _ = await runner.syncTick()
        #expect(SyncFakeGmail.units(fake.calls) - 2 == 50, "\(fake.calls)")
        #expect(fake.modifies(of: "t1").count == 1)
    }

    @Test func propagationNoOpCosts40() async throws {
        let runner = env.runner()
        await warmUp(runner)
        let u = try #require(env.labelID("Lajittelu/Uutiskirjeet"))
        let m = try #require(env.labelID("Lajittelu/Luokiteltu"))
        fake.deliver("t1", labels: ["INBOX", "UNREAD", u, m])            // nothing missing
        _ = await runner.syncTick()
        #expect(SyncFakeGmail.units(fake.calls) - 2 == 40, "\(fake.calls)")
        #expect(fake.writes.isEmpty)
    }

    @Test func sentOnlyThreadCosts40() async throws {
        let runner = env.runner()
        await warmUp(runner)
        fake.sendMail("s1", to: ["kalle@example.fi"])
        _ = await runner.syncTick()
        #expect(SyncFakeGmail.units(fake.calls) - 2 == 40, "\(fake.calls)")
    }

    /// 200 new threads: the sorter waits on its 2,000/min budget while a due wake completes in its own tick.
    @MainActor
    @Test func sorterStaysUnder2000PerMinuteWhileADueWakeCompletes() async throws {
        let runner = env.runner()
        await warmUp(runner)
        for i in 1...200 { env.newsletter(String(format: "n%03d", i)) }
        fake.labels.addSnoozedThread("snoozed", wake: "20261005T0800Z")
        let clock = env.clock
        let finished = Counter()
        let sync = Task {
            _ = await runner.syncTick()
            finished.increment()
        }
        #expect(await eventually { clock.sleeperCount >= 1 })            // the budget is waiting
        let reads = fake.count("thread headers n")
        #expect(reads >= 1 && reads <= 50)
        #expect(finished.count == 0)

        let wake = Task { await runner.wakeTick() }
        _ = await valueWithin(wake, "wake tick while the sorter waits")
        #expect(fake.modifies(of: "snoozed").count == 1)

        for _ in 0..<30 where finished.count == 0 {
            let _: Bool = await eventually { finished.count == 1 || clock.sleeperCount >= 1 }
            clock.advanceToNextDeadline()
        }
        await valueWithin(sync, "sorter")
        for i in 1...200 {
            let id = String(format: "n%03d", i)
            #expect(fake.labelNames(of: id).contains("Lajittelu/Uutiskirjeet"), "\(id)")
        }
        let sorter = fake.timedCalls.filter { $0.call.hasPrefix("thread headers n") || $0.call.hasPrefix("modify n") }
        for (i, first) in sorter.enumerated() {
            let window = sorter[i...].prefix { $0.at < first.at.addingTimeInterval(60) }
            #expect(SyncFakeGmail.units(window.map(\.call)) <= 2_000)
        }
        #expect(clock.now() >= daemonEpoch.addingTimeInterval(60 + 4 * 60))   // 10,000 units at 2,000/min
    }

    // MARK: GmailQuotaPrice

    @Test(arguments: GmailEndpointTests.table)
    func quotaPriceMatchesTheEndpointTable(_ row: GmailEndpointTests.Row) {
        let request = GmailEndpointTests.request(row.method, row.path)
        #expect(GmailQuotaPrice.units(for: request) == GmailEndpoint(request)?.units)
        #expect(GmailQuotaPrice.units(for: request) == row.units)
    }

    @Test func quotaPriceIgnoresOtherHosts() {
        #expect(GmailQuotaPrice.units(for: GmailEndpointTests.request("POST", "https://oauth2.googleapis.com/token")) == nil)
    }

    @Test func daemonShareIs3000PerMinute() {
        #expect(GmailQuotaPolicy.daemon.share == 0.20)
        #expect(GmailQuotaPolicy.daemon.maxInFlight == 4)
    }

    @Test func defaultSorterBudgetLeavesAThousandForWakes() {
        #expect(DaemonConfig().sync.unitsPerMinute == 2_000)
        #expect(Double(GmailQuotaPolicy.daemon.perUserLimit) * GmailQuotaPolicy.daemon.share - 2_000 >= 1_000)
    }
}

/// `MinuteBudget`: a rolling 60 s window; `spend` sleeps until the units fit, never fails for lack of quota.
@Suite struct MinuteBudgetTests {
    @Test func spendsWithinTheWindowDoNotSleep() async throws {
        let clock = TestDaemonClock(daemonEpoch, autoAdvance: true)
        let budget = MinuteBudget(unitsPerMinute: 2_000, clock: clock)
        for _ in 0..<40 { try await budget.spend(50) }
        #expect(clock.now() == daemonEpoch)
        #expect(clock.requested.allSatisfy { $0 <= daemonEpoch })
    }

    @Test func overspendWaitsForTheOldestCharge() async throws {
        let clock = TestDaemonClock(daemonEpoch, autoAdvance: true)
        let budget = MinuteBudget(unitsPerMinute: 2_000, clock: clock)
        try await budget.spend(1_000)
        clock.advance(by: 30)
        try await budget.spend(1_000)
        try await budget.spend(100)                                        // fits once the first 1,000 expire
        #expect(clock.now() == daemonEpoch.addingTimeInterval(60))
        try await budget.spend(1_000)                                      // 1,100 in the window: until t+90
        #expect(clock.now() == daemonEpoch.addingTimeInterval(90))
    }

    @Test func pacedSpendNeverExceedsTheRate() async throws {
        let clock = TestDaemonClock(daemonEpoch, autoAdvance: true)
        let budget = MinuteBudget(unitsPerMinute: 2_000, clock: clock)
        var charges: [(Date, Int)] = []
        for i in 0..<400 {
            let units = i.isMultiple(of: 2) ? 40 : 10
            try await budget.spend(units)
            charges.append((clock.now(), units))
        }
        for (i, first) in charges.enumerated() {
            let inWindow = charges[i...].prefix { $0.0 < first.0.addingTimeInterval(60) }.reduce(0) { $0 + $1.1 }
            #expect(inWindow <= 2_000)
        }
        #expect(clock.now() >= daemonEpoch.addingTimeInterval(4 * 60))    // 10,000 units
    }

    @Test func cancellationEndsTheWait() async throws {
        let clock = TestDaemonClock(daemonEpoch)
        let budget = MinuteBudget(unitsPerMinute: 100, clock: clock)
        try await budget.spend(100)
        let task = Task { try await budget.spend(50) }
        #expect(await eventually { clock.sleeperCount == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func wallClockStepBackwardsDoesNotBlockForever() async throws {
        let clock = TestDaemonClock(daemonEpoch, autoAdvance: true)
        let budget = MinuteBudget(unitsPerMinute: 100, clock: clock)
        try await budget.spend(100)
        clock.set(daemonEpoch.addingTimeInterval(-3_600))                  // NTP stepped the clock back an hour
        try await budget.spend(50)
        // At most one window from the step, never the size of the step (here 3,660 s).
        #expect(clock.now() <= daemonEpoch.addingTimeInterval(-3_600 + 60))
    }
}

/// `ProbeTransport` (base layer): Date-header skew and priced units in the last minute.
@Suite struct ProbeTransportTests {
    let clock = TestClock(daemonEpoch)

    @Test func countsPricedUnitsOfTheLastMinute() async throws {
        let base = DateHeaderTransport(clock: clock.closure)
        let probe = ProbeTransport(base: base, now: clock.closure)
        _ = try await probe.send(gmailRequest("GET", "history?startHistoryId=1"))
        _ = try await probe.send(gmailRequest("GET", "threads/t1?format=metadata"))
        clock.advance(by: 30)
        _ = try await probe.send(gmailRequest("POST", "threads/t1/modify"))
        var token = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        token.httpMethod = "POST"
        _ = try await probe.send(token)
        #expect(probe.unitsLastMinute == 52)
        clock.advance(by: 31)
        #expect(probe.unitsLastMinute == 10)
        clock.advance(by: 30)
        #expect(probe.unitsLastMinute == 0)
        #expect(base.requests.count == 4)                                  // everything passes through
    }

    @Test func measuresSkewFromTheDateHeader() async throws {
        let base = DateHeaderTransport(clock: clock.closure)
        base.setServerOffset(5)
        let probe = ProbeTransport(base: base, now: clock.closure)
        #expect(probe.skew == nil)
        _ = try await probe.send(gmailRequest("GET", "labels"))
        let skew = try #require(probe.skew)
        #expect(abs(abs(skew.seconds) - 5) < 1.0)
        #expect(skew.measuredAt == daemonEpoch)
        clock.advance(by: 120)
        base.setServerOffset(-200)
        _ = try await probe.send(gmailRequest("GET", "labels"))
        #expect(abs(abs(try #require(probe.skew).seconds) - 200) < 1.0)
        #expect(probe.skew?.measuredAt == daemonEpoch.addingTimeInterval(120))
    }

    @Test func noDateHeaderNoSkew() async throws {
        let probe = ProbeTransport(base: StubTransport { _ in (200, Data("{}".utf8)) }, now: clock.closure)
        _ = try await probe.send(gmailRequest("GET", "labels"))
        #expect(probe.skew == nil)
        #expect(probe.unitsLastMinute == 1)
    }

    @Test func responsesPassThroughUnchanged() async throws {
        let probe = ProbeTransport(base: StubTransport { _ in (418, Data("teapot".utf8)) }, now: clock.closure)
        let (data, response) = try await probe.send(gmailRequest("GET", "labels"))
        #expect(response.statusCode == 418)
        #expect(String(decoding: data, as: UTF8.self) == "teapot")
    }
}
