import Foundation
import Testing
@testable import MailCore

@Suite struct GmailQuotaSchedulerTests {
    let clock = ManualQuotaClock()
    let small = GmailQuotaPolicy(perUserLimit: 100, share: 1, backgroundShare: 1)

    @Test func admitsImmediatelyWhenThereIsRoom() async throws {
        let scheduler = GmailQuotaScheduler(policy: .macApp, clock: clock)
        let ticket = try await scheduler.acquire(units: 40, lane: .background, deadline: .seconds(90))
        #expect(ticket.units == 40)
        #expect(await scheduler.snapshot.windowUnits == 40)
        #expect(await scheduler.snapshot.inFlight == 1)
        await scheduler.finished(ticket, gotHTTPResponse: true)
        #expect(await scheduler.snapshot.inFlight == 0)
    }

    @Test func waitsForTheWindowThenAdmits() async throws {
        let scheduler = GmailQuotaScheduler(policy: small, clock: clock)
        let first = try await scheduler.acquire(units: 100, lane: .interactive, deadline: .seconds(500))
        await scheduler.finished(first, gotHTTPResponse: true)
        let waiting = Task { try await scheduler.acquire(units: 10, lane: .interactive, deadline: .seconds(500)) }
        #expect(await eventually { await scheduler.snapshot.queued == 1 })
        #expect(await eventually { clock.nextDeadline == .seconds(60) })
        clock.advance(to: .seconds(60))
        let ticket = try await waiting.value
        #expect(ticket.units == 10)
    }

    @Test func deadlineFailsWithRateLimitedWithoutCharging() async throws {
        let scheduler = GmailQuotaScheduler(policy: small, clock: clock)
        let first = try await scheduler.acquire(units: 100, lane: .interactive, deadline: .seconds(500))
        await scheduler.finished(first, gotHTTPResponse: true)
        let waiting = Task { try await scheduler.acquire(units: 10, lane: .interactive, deadline: .seconds(30)) }
        #expect(await eventually { clock.nextDeadline == .seconds(30) })
        clock.advance(to: .seconds(30))
        await #expect(throws: GmailError.rateLimited) { try await waiting.value }
        #expect(await scheduler.snapshot.windowUnits == 100)
        #expect(await scheduler.snapshot.queued == 0)
    }

    @Test func cancelWhileQueuedThrowsURLErrorCancelled() async throws {
        let scheduler = GmailQuotaScheduler(policy: small, clock: clock)
        let first = try await scheduler.acquire(units: 100, lane: .interactive, deadline: .seconds(500))
        await scheduler.finished(first, gotHTTPResponse: true)
        let waiting = Task { try await scheduler.acquire(units: 10, lane: .interactive, deadline: .seconds(500)) }
        #expect(await eventually { await scheduler.snapshot.queued == 1 })
        waiting.cancel()
        do {
            _ = try await waiting.value
            Issue.record("expected cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(await scheduler.snapshot.queued == 0)
        #expect(await scheduler.snapshot.windowUnits == 100)
    }

    @Test func sharedCooldownHoldsEveryoneThenProbes() async throws {
        let scheduler = GmailQuotaScheduler(policy: .macApp, clock: clock)
        let ticket = try await scheduler.acquire(units: 40, lane: .interactive, deadline: .seconds(90))
        let cooldownEnd = await scheduler.rateLimited(ticket, retryAfter: nil)
        #expect(cooldownEnd == .seconds(1))
        let a = Task { try await scheduler.acquire(units: 40, lane: .interactive, deadline: .seconds(90)) }
        #expect(await eventually { await scheduler.snapshot.queued == 1 })
        let b = Task { try await scheduler.acquire(units: 40, lane: .interactive, deadline: .seconds(90)) }
        #expect(await eventually { await scheduler.snapshot.queued == 2 })
        clock.advance(to: .seconds(1))
        let probe = try await a.value                                  // FIFO: a is the probe
        #expect(await scheduler.snapshot.queued == 1)                 // b waits for the probe's answer
        await scheduler.finished(probe, gotHTTPResponse: true)
        let next = try await b.value
        #expect(next.epoch == probe.epoch)
    }

    /// A slow request holding the half-open gate must not keep others queued past their deadline.
    @Test func waiterFailsAtItsDeadlineWhileASlowRequestIsInFlight() async throws {
        let scheduler = GmailQuotaScheduler(policy: .macApp, clock: clock)
        let slow = try await scheduler.acquire(units: 100, lane: .interactive, deadline: .seconds(90))
        let limited = try await scheduler.acquire(units: 10, lane: .interactive, deadline: .seconds(90))
        _ = await scheduler.rateLimited(limited, retryAfter: nil)
        let waiting = Task { try await scheduler.acquire(units: 10, lane: .interactive, deadline: .seconds(91)) }
        #expect(await eventually { await scheduler.snapshot.queued == 1 })
        clock.advance(to: .seconds(2))
        #expect(await eventually { clock.nextDeadline == .seconds(91) })
        clock.advance(to: .seconds(91))
        #expect(await eventually { await scheduler.snapshot.queued == 0 })
        await scheduler.finished(slow, gotHTTPResponse: true)      // (unblocks the waiter either way)
        await #expect(throws: GmailError.rateLimited) { try await waiting.value }
    }
}
