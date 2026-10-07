import Foundation
import Testing
@testable import MailCore

@Suite struct WakePolicyTests {
    let now = D(1_791_018_000)

    func report(woken: [String] = [], cancelled: [String] = [], next: Date? = nil, skipped: Bool = false) -> WakeReport {
        var r = WakeReport()
        r.woken = woken
        r.cancelled = cancelled
        r.nextWakeAt = next
        r.skipped = skipped
        return r
    }

    // MARK: - WakeOutcome

    @Test func outcomeFromReport() {
        #expect(WakeOutcome(report: report(woken: ["x"])) == .completed(woken: 1, cancelled: 0, nextWakeAt: nil))
        #expect(WakeOutcome(report: report(skipped: true)) == .skipped)
        #expect(WakeOutcome(report: report()) == .completed(woken: 0, cancelled: 0, nextWakeAt: nil))
        #expect(WakeOutcome(report: report(woken: ["a", "b"], cancelled: ["c"], next: now.addingTimeInterval(120)))
                == .completed(woken: 2, cancelled: 1, nextWakeAt: now.addingTimeInterval(120)))
    }

    @Test func outcomeFromReportIgnoresFailedThreads() {
        var r = report(woken: ["a"])
        r.failedThreadIDs = ["b"]
        #expect(WakeOutcome(report: r) == .completed(woken: 1, cancelled: 0, nextWakeAt: nil))
    }

    @Test func outcomeFromError() {
        #expect(WakeOutcome(error: GmailError.offline) == .offline)
        #expect(WakeOutcome(error: GmailError.rateLimited) == .rateLimited)
        #expect(WakeOutcome(error: AuthError.invalidGrant) == .signInExpired)
        #expect(WakeOutcome(error: AuthError.notSignedIn) == .signInExpired)
        #expect(WakeOutcome(error: AuthError.badResponse) == .failed)
        #expect(WakeOutcome(error: AuthError.stateMismatch) == .failed)
        #expect(WakeOutcome(error: GmailError.http(500, "")) == .failed)
        #expect(WakeOutcome(error: GmailError.http(401, "")) == .failed)
        #expect(WakeOutcome(error: GmailError.decoding) == .failed)
        #expect(WakeOutcome(error: URLError(.notConnectedToInternet)) == .failed)
        #expect(WakeOutcome(error: CancellationError()) == .cancelled)
        #expect(WakeOutcome(error: URLError(.cancelled)) == .cancelled)
    }

    // MARK: - WakePolicy

    @Test func defaultsAreTheContract() {
        let p = WakePolicy()
        #expect(p.interval == 300)
        #expect(p.offlineRetry == 60)
        #expect(p.followsNextWake == false)
        #expect(p.minimumGap == 60)
        #expect(p == WakePolicy(interval: 300, offlineRetry: 60, followsNextWake: false, minimumGap: 60))
    }

    @Test func delays() {
        let p = WakePolicy()
        #expect(p.delay(after: .completed(woken: 1, cancelled: 0, nextWakeAt: nil), now: now) == 300)
        #expect(p.delay(after: .completed(woken: 0, cancelled: 0, nextWakeAt: nil), now: now) == 300)
        #expect(p.delay(after: .offline, now: now) == 60)
        #expect(p.delay(after: .rateLimited, now: now) == 60)
        for outcome: WakeOutcome in [.failed, .skipped, .paused, .signInExpired, .cancelled] {
            #expect(p.delay(after: outcome, now: now) == 300)
        }
    }

    @Test func customIntervals() {
        let p = WakePolicy(interval: 600, offlineRetry: 30)
        #expect(p.delay(after: .completed(woken: 0, cancelled: 0, nextWakeAt: nil), now: now) == 600)
        #expect(p.delay(after: .failed, now: now) == 600)
        #expect(p.delay(after: .offline, now: now) == 30)
        #expect(p.delay(after: .rateLimited, now: now) == 30)
    }

    @Test func followsNextWakeOffByDefault() {
        let p = WakePolicy()
        #expect(p.delay(after: .completed(woken: 0, cancelled: 0, nextWakeAt: now.addingTimeInterval(120)), now: now) == 300)
        #expect(p.delay(after: .completed(woken: 0, cancelled: 0, nextWakeAt: now.addingTimeInterval(10)), now: now) == 300)
    }

    @Test func followsNextWakeOn() {
        let p = WakePolicy(followsNextWake: true)
        func delay(_ next: Date?) -> TimeInterval {
            p.delay(after: .completed(woken: 0, cancelled: 0, nextWakeAt: next), now: now)
        }
        #expect(delay(now.addingTimeInterval(120)) == 120)
        #expect(delay(now.addingTimeInterval(10)) == 60)
        #expect(delay(now.addingTimeInterval(3600)) == 300)
        #expect(delay(now.addingTimeInterval(-30)) == 60)                    // already due: minimumGap
        #expect(delay(nil) == 300)
        #expect(p.delay(after: .offline, now: now) == 60)
        #expect(p.delay(after: .failed, now: now) == 300)
    }

    @Test func followsNextWakeHonoursMinimumGap() {
        let p = WakePolicy(followsNextWake: true, minimumGap: 90)
        #expect(p.delay(after: .completed(woken: 0, cancelled: 0, nextWakeAt: now.addingTimeInterval(30)), now: now) == 90)
        #expect(p.delay(after: .completed(woken: 0, cancelled: 0, nextWakeAt: now.addingTimeInterval(200)), now: now) == 200)
    }
}
