import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §6.3 wake loop and D15: ticks at mm:02 (sync at mm:20), cleanup only in live with a fresh skew ≤ 120 s, and
/// the app's waker plus the daemon's staying idempotent.
@Suite struct WakeLoopTests {
    let env: DaemonEnv
    /// 2026-10-05 09:00:00Z.
    static let minute0 = D(1_791_190_800)

    init() throws {
        env = try DaemonEnv()
        try env.writeToken()
        try env.seedState(watermark: "1000")
        try env.setConfig(wake: .live, sorting: .shadow)
    }

    var fake: SyncFakeGmail { env.fake }

    // MARK: Schedule

    @Test func loopsTickAtSecond2AndSecond20() async throws {
        env.clock.set(Self.minute0.addingTimeInterval(30.5))
        let runner = env.runner()
        let clock = env.clock
        let task = Task { await runner.run() }
        #expect(await eventually { clock.sleeperCount >= 2 })
        #expect(clock.requested.contains(Self.minute0.addingTimeInterval(62)))     // 09:01:02 wake
        #expect(clock.requested.contains(Self.minute0.addingTimeInterval(80)))     // 09:01:20 sync
        clock.advance(to: Self.minute0.addingTimeInterval(62))
        #expect(await eventually { fake.calls.contains("list labels") && clock.sleeperCount >= 2 })
        #expect(clock.requested.contains(Self.minute0.addingTimeInterval(122)))    // next wake at 09:02:02
        #expect(fake.historyStarts.isEmpty)                                        // sync has not ticked yet
        clock.advance(to: Self.minute0.addingTimeInterval(80))
        #expect(await eventually { !fake.historyStarts.isEmpty })
        task.cancel()
        await task.value
    }

    @Test func clockStepRecomputesTheNextTick() async throws {
        env.clock.set(Self.minute0.addingTimeInterval(30))
        let runner = env.runner()
        let clock = env.clock
        let task = Task { await runner.run() }
        #expect(await eventually { clock.sleeperCount >= 2 })
        clock.set(Self.minute0.addingTimeInterval(3_600 + 40))                      // asleep for an hour
        clock.advance(by: 0)
        #expect(await eventually { clock.requested.contains(Self.minute0.addingTimeInterval(3_600 + 62)) })
        task.cancel()
        await task.value
    }

    @Test func runReturnsPromptlyWhenCancelled() async throws {
        let runner = env.runner()
        let clock = env.clock
        let task = Task { await runner.run() }
        #expect(await eventually { clock.sleeperCount >= 2 })
        task.cancel()
        await valueWithin(task, "run() after cancel")
    }

    // MARK: Cleanup guard (D15)

    struct SkewCase: Sendable, CustomTestStringConvertible {
        var wake: FeatureMode
        var serverAhead: TimeInterval?
        var measuredAgo: TimeInterval
        var cleans: Bool
        var testDescription: String { "\(wake) skew \(serverAhead.map { "\($0)" } ?? "none") \(Int(measuredAgo)) s ago → \(cleans)" }
    }

    static let skewCases = [
        SkewCase(wake: .live, serverAhead: 5, measuredAgo: 0, cleans: true),
        SkewCase(wake: .live, serverAhead: -100, measuredAgo: 0, cleans: true),
        SkewCase(wake: .live, serverAhead: 119, measuredAgo: 9 * 60, cleans: true),
        SkewCase(wake: .live, serverAhead: 300, measuredAgo: 0, cleans: false),
        SkewCase(wake: .live, serverAhead: -300, measuredAgo: 0, cleans: false),
        SkewCase(wake: .live, serverAhead: 5, measuredAgo: 11 * 60, cleans: false),
        SkewCase(wake: .live, serverAhead: nil, measuredAgo: 0, cleans: false),
        SkewCase(wake: .shadow, serverAhead: 5, measuredAgo: 0, cleans: false),
    ]

    @Test(arguments: skewCases)
    func cleanupNeedsLiveAndAFreshSmallSkew(_ c: SkewCase) async throws {
        try env.setConfig(wake: c.wake, sorting: .shadow)
        let stale = fake.labels.addLabel("Torkku/20261005T0700Z", visibility: .hidden)   // two hours past
        let runner = env.runner()
        _ = await runner.wakeTick()                                       // no measurement yet: plain waker
        #expect(!fake.calls.contains("label delete \(stale)"))
        if let ahead = c.serverAhead { try await env.measureSkew(aheadBy: ahead) }
        env.clock.advance(by: c.measuredAgo)
        _ = await runner.wakeTick()
        #expect(fake.calls.contains("label delete \(stale)") == c.cleans)
        if !c.cleans { #expect(fake.labels.labelID("Torkku/20261005T0700Z") == stale) }
    }

    @Test func firstTickAfterStartNeverCleans() async throws {
        let stale = fake.labels.addLabel("Torkku/20261005T0700Z", visibility: .hidden)
        _ = await env.runner().wakeTick()
        #expect(!fake.calls.contains("label delete \(stale)"))
        #expect(fake.calls.contains("list labels"))
    }

    // MARK: Waking

    @Test func dueThreadWakesInLive() async throws {
        fake.labels.addSnoozedThread("a", wake: "20261005T0800Z")
        _ = await env.runner().wakeTick()
        #expect(fake.modifies(of: "a").count == 1)
        #expect(fake.labelNames(of: "a").isSuperset(of: ["INBOX", "UNREAD"]))
        #expect(env.logText.contains("woken=1"))
    }

    @Test func shadowWakeIsLoggedAsVarjo() async throws {
        try env.setConfig(wake: .shadow, sorting: .shadow)
        fake.labels.addSnoozedThread("a", wake: "20261005T0800Z")
        _ = await env.runner().wakeTick()
        #expect(fake.modifies(of: "a").isEmpty)
        #expect(env.logText.contains("VARJO"))
    }

    @Test func wakeOffMakesNoCalls() async throws {
        try env.setConfig(wake: .off, sorting: .off)
        fake.labels.addSnoozedThread("a", wake: "20261005T0800Z")
        _ = await env.runner().wakeTick()
        #expect(fake.count("list labelIds") == 0)
        #expect(fake.modifies(of: "a").isEmpty)
    }

    @Test func wakeRunsWhileSortingIsOff() async throws {
        try env.setConfig(wake: .live, sorting: .off)
        fake.labels.addSnoozedThread("a", wake: "20261005T0800Z")
        let runner = env.runner()
        _ = await runner.wakeTick()
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "a").count == 1)
        #expect(fake.historyStarts.isEmpty)
    }

    @Test func appWakerAndDaemonTogetherStayIdempotent() async throws {
        let clock = env.clock
        let app = SnoozeWaker(api: fake.labels, directory: LabelDirectory(api: fake.labels), options: SnoozeWaker.Options(),
                              now: { clock.now() })
        let runner = env.runner()
        fake.labels.addSnoozedThread("a", wake: "20261005T0800Z")
        _ = try await app.runOnce()
        _ = await runner.wakeTick()
        #expect(fake.modifies(of: "a").count == 1)

        fake.labels.addSnoozedThread("b", wake: "20261005T0830Z")
        _ = await runner.wakeTick()
        _ = try await app.runOnce()
        #expect(fake.modifies(of: "b").count == 1)
        #expect(fake.labelNames(of: "a").isSuperset(of: ["INBOX", "UNREAD"]))
        #expect(fake.labelNames(of: "b").isSuperset(of: ["INBOX", "UNREAD"]))
    }

    @Test func offlineWakeTickIsRetriedNextMinute() async throws {
        fake.labels.addSnoozedThread("a", wake: "20261005T0800Z")
        let runner = env.runner()
        fake.base.update { $0.offline = true }
        let outcome = await runner.wakeTick()
        #expect(outcome == .offline)
        fake.base.update { $0.offline = false }
        env.clock.advance(by: 60)
        _ = await runner.wakeTick()
        #expect(fake.modifies(of: "a").count == 1)
        guard case .running = await runner.phase else { Issue.record("expected .running"); return }
    }
}
