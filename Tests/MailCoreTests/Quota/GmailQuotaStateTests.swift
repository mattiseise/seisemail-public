import Foundation
import Testing
@testable import MailCore

@Suite struct GmailQuotaStateTests {
    typealias Ticket = GmailQuotaState.Ticket
    let policy = GmailQuotaPolicy.macApp

    /// Pumps and immediately finishes everything admitted until nothing more fits.
    func drain(_ state: inout GmailQuotaState, now: Duration) -> (admitted: [Ticket], wakeAt: Duration?) {
        var all: [Ticket] = []
        while true {
            let pump = state.pump(now: now)
            if pump.admitted.isEmpty { return (all, pump.wakeAt) }
            all += pump.admitted
            for t in pump.admitted { state.finished(t, gotHTTPResponse: true, now: now) }
        }
    }

    func enqueue(_ state: inout GmailQuotaState, _ count: Int, from first: UInt64 = 0, units: Int = 40,
                 lane: GmailLane, deadline: Duration = .seconds(90)) {
        for i in 0..<UInt64(count) {
            state.enqueue(id: first + i, units: units, lane: lane, deadline: deadline)
        }
    }

    @Test func policyNumbers() {
        #expect(policy.perUserLimit == 15_000)
        #expect(policy.ceiling == 10_500)
        #expect(policy.backgroundCeiling == 7_500)
        #expect(GmailQuotaPolicy.daemon.ceiling == 3_000)
        #expect(policy.ceiling + GmailQuotaPolicy.daemon.ceiling < policy.perUserLimit)
    }

    @Test func backgroundStopsAtItsShare() {
        var state = GmailQuotaState(policy: policy)
        enqueue(&state, 200, lane: .background)
        let (admitted, wakeAt) = drain(&state, now: .zero)
        #expect(admitted.count == 187)                       // 187 × 40 = 7,480 ≤ 7,500
        #expect(state.windowUnits(now: .zero) == 7_480)
        #expect(wakeAt == .seconds(60))
        #expect(drain(&state, now: .seconds(59)).admitted.isEmpty)
        #expect(drain(&state, now: .seconds(60)).admitted.count == 13)
    }

    @Test func interactiveUsesReserveUpToCeiling() {
        var state = GmailQuotaState(policy: policy)
        enqueue(&state, 187, lane: .background)
        _ = drain(&state, now: .zero)
        enqueue(&state, 100, from: 1_000, lane: .interactive)
        let (admitted, wakeAt) = drain(&state, now: .zero)
        #expect(admitted.count == 75)                        // 7,480 + 75 × 40 = 10,480 ≤ 10,500
        #expect(state.windowUnits(now: .zero) == 10_480)
        #expect(wakeAt == .seconds(60))
    }

    @Test func windowSlidesExactly() {
        var state = GmailQuotaState(policy: GmailQuotaPolicy(perUserLimit: 100, share: 1, backgroundShare: 1))
        state.enqueue(id: 1, units: 60, lane: .background, deadline: .seconds(500))
        _ = drain(&state, now: .zero)
        state.enqueue(id: 2, units: 40, lane: .background, deadline: .seconds(500))
        _ = drain(&state, now: .seconds(30))
        state.enqueue(id: 3, units: 40, lane: .background, deadline: .seconds(500))
        #expect(drain(&state, now: .seconds(30)).wakeAt == .seconds(60))
        #expect(drain(&state, now: .milliseconds(59_999)).admitted.isEmpty)
        #expect(drain(&state, now: .seconds(60)).admitted.map(\.id) == [3])
        state.enqueue(id: 4, units: 60, lane: .background, deadline: .seconds(500))
        let blocked = drain(&state, now: .seconds(60))
        #expect(blocked.admitted.isEmpty)
        #expect(blocked.wakeAt == .seconds(90))              // the 40 charged at 30 s frees at 90 s
        #expect(drain(&state, now: .seconds(90)).admitted.map(\.id) == [4])
    }

    @Test func strictPriorityInteractiveFirst() {
        var state = GmailQuotaState(policy: GmailQuotaPolicy(maxInFlight: 1))
        state.enqueue(id: 1, units: 40, lane: .background, deadline: .seconds(90))
        state.enqueue(id: 2, units: 40, lane: .background, deadline: .seconds(90))
        state.enqueue(id: 3, units: 10, lane: .interactive, deadline: .seconds(90))
        let first = state.pump(now: .zero)
        #expect(first.admitted.map(\.id) == [3])
        state.finished(first.admitted[0], gotHTTPResponse: true, now: .zero)
        #expect(state.pump(now: .zero).admitted.map(\.id) == [1])     // FIFO within the lane
    }

    @Test func inFlightCaps8And6() {
        var state = GmailQuotaState(policy: policy)
        enqueue(&state, 10, lane: .background)
        #expect(state.pump(now: .zero).admitted.count == 6)
        enqueue(&state, 10, from: 100, lane: .interactive)
        let more = state.pump(now: .zero)
        #expect(more.admitted.count == 2)
        #expect(more.admitted.allSatisfy { $0.lane == .interactive })
        #expect(state.inFlight == 8)
        #expect(state.backgroundInFlight == 6)
    }

    @Test func cancelledWaiterNotCharged() {
        var state = GmailQuotaState(policy: GmailQuotaPolicy(maxInFlight: 1))
        state.enqueue(id: 1, units: 40, lane: .interactive, deadline: .seconds(90))
        state.enqueue(id: 2, units: 40, lane: .interactive, deadline: .seconds(90))
        let pump = state.pump(now: .zero)
        #expect(pump.admitted.map(\.id) == [1])
        let cancelledQueued = state.cancel(id: 2)
        let cancelledAdmitted = state.cancel(id: 1)
        #expect(cancelledQueued)
        #expect(cancelledAdmitted == false)                 // already admitted
        state.finished(pump.admitted[0], gotHTTPResponse: true, now: .zero)
        #expect(state.pump(now: .zero).admitted.isEmpty)
        #expect(state.windowUnits(now: .zero) == 40)
        #expect(state.queued == 0)
    }

    @Test func expiredWaiterNeverSent() {
        var state = GmailQuotaState(policy: GmailQuotaPolicy(perUserLimit: 100, share: 1, backgroundShare: 1))
        state.enqueue(id: 1, units: 100, lane: .interactive, deadline: .seconds(500))
        _ = drain(&state, now: .zero)
        state.enqueue(id: 2, units: 40, lane: .interactive, deadline: .seconds(30))
        #expect(state.pump(now: .zero).wakeAt == .seconds(30))       // the deadline comes before the window frees
        let pump = state.pump(now: .seconds(30))
        #expect(pump.expired == [2])
        #expect(pump.admitted.isEmpty)
        #expect(state.windowUnits(now: .seconds(30)) == 100)
    }

    @Test func oversizedAdmittedOnEmptyWindow() {
        var state = GmailQuotaState(policy: GmailQuotaPolicy(perUserLimit: 400, share: 0.20, backgroundShare: 0.20))
        #expect(state.policy.ceiling == 80)
        state.enqueue(id: 1, units: 100, lane: .interactive, deadline: .seconds(500))
        state.enqueue(id: 2, units: 100, lane: .interactive, deadline: .seconds(500))
        let (admitted, wakeAt) = drain(&state, now: .zero)
        #expect(admitted.map(\.id) == [1])
        #expect(wakeAt == .seconds(60))
        #expect(drain(&state, now: .seconds(60)).admitted.map(\.id) == [2])
    }

    /// Strikes in a row, each probe sent the moment the previous cooldown ends.
    func cooldowns(jitter: Double, count: Int) -> [Duration] {
        var state = GmailQuotaState(policy: policy)
        var now = Duration.zero
        var out: [Duration] = []
        for i in 0..<UInt64(count) {
            state.enqueue(id: i, units: 10, lane: .interactive, deadline: .seconds(1_000))
            let pump = state.pump(now: now)
            guard let ticket = pump.admitted.first else { return out }
            let wait = state.rateLimited(ticket, retryAfter: nil, jitter: jitter, now: now)
            out.append(wait)
            now += wait
        }
        return out
    }

    @Test func backoffSchedule() {
        let plain = cooldowns(jitter: 0, count: 7)
        #expect(plain == [1, 2, 4, 8, 16, 32, 32].map { Duration.seconds($0) })
        let sixTotal = plain.prefix(6).reduce(Duration.zero, +)
        #expect(sixTotal == .seconds(63))
        #expect(sixTotal >= policy.window)                  // the last retry lands after the window turned over
        #expect(cooldowns(jitter: 1, count: 7) == [2, 3, 5, 9, 17, 33, 33].map { Duration.seconds($0) })
    }

    @Test func retryAfterWinsWhenLonger() {
        var state = GmailQuotaState(policy: policy)
        state.enqueue(id: 1, units: 10, lane: .interactive, deadline: .seconds(90))
        let t1 = state.pump(now: .zero).admitted[0]
        #expect(state.rateLimited(t1, retryAfter: .seconds(20), jitter: 0, now: .zero) == .seconds(20))

        var other = GmailQuotaState(policy: policy)
        other.enqueue(id: 1, units: 10, lane: .interactive, deadline: .seconds(90))
        let t2 = other.pump(now: .zero).admitted[0]
        #expect(other.rateLimited(t2, retryAfter: .milliseconds(300), jitter: 0, now: .zero) == .seconds(1))
    }

    @Test func staleTicketDoesNotEscalate() {
        var state = GmailQuotaState(policy: policy)
        enqueue(&state, 6, lane: .interactive)
        let tickets = state.pump(now: .zero).admitted
        #expect(tickets.count == 6)
        var waits: [Duration] = []
        for t in tickets { waits.append(state.rateLimited(t, retryAfter: nil, jitter: 0, now: .zero)) }
        #expect(state.strikes == 1)
        #expect(waits.allSatisfy { $0 == .seconds(1) })
        #expect(state.inFlight == 0)
    }

    @Test func halfOpenAdmitsOneThenOpensOnSuccess() {
        var state = GmailQuotaState(policy: policy)
        state.enqueue(id: 0, units: 10, lane: .interactive, deadline: .seconds(90))
        let first = state.pump(now: .zero).admitted[0]
        _ = state.rateLimited(first, retryAfter: nil, jitter: 0, now: .zero)
        enqueue(&state, 4, from: 1, lane: .interactive)
        let during = state.pump(now: .milliseconds(500))
        #expect(during.admitted.isEmpty)
        #expect(during.wakeAt == .seconds(1))
        let probe = state.pump(now: .seconds(1))
        #expect(probe.admitted.map(\.id) == [1])
        #expect(state.pump(now: .seconds(1)).admitted.isEmpty)       // nothing else while the probe is out
        state.finished(probe.admitted[0], gotHTTPResponse: true, now: .seconds(1))
        #expect(state.halfOpen == false)
        #expect(state.pump(now: .seconds(1)).admitted.map(\.id) == [2, 3, 4])
    }

    @Test func staleSuccessDoesNotReopen() {
        var state = GmailQuotaState(policy: policy)
        enqueue(&state, 2, lane: .interactive)
        let tickets = state.pump(now: .zero).admitted
        _ = state.rateLimited(tickets[0], retryAfter: nil, jitter: 0, now: .zero)
        state.finished(tickets[1], gotHTTPResponse: true, now: .zero)     // admitted before the strike
        #expect(state.halfOpen)
    }

    @Test func transportErrorKeepsHalfOpenWithoutDeadlock() {
        var state = GmailQuotaState(policy: policy)
        state.enqueue(id: 0, units: 10, lane: .interactive, deadline: .seconds(90))
        _ = state.rateLimited(state.pump(now: .zero).admitted[0], retryAfter: nil, jitter: 0, now: .zero)
        enqueue(&state, 3, from: 1, lane: .interactive)
        let probe = state.pump(now: .seconds(1)).admitted
        #expect(probe.map(\.id) == [1])
        state.finished(probe[0], gotHTTPResponse: false, now: .seconds(1))
        #expect(state.halfOpen)
        #expect(state.pump(now: .seconds(1)).admitted.map(\.id) == [2])  // the next request is the new probe
    }

    @Test func scaleHalvesToFloorAndRecoversPerQuietWindow() {
        var state = GmailQuotaState(policy: policy)
        var now = Duration.zero
        for i in 0..<UInt64(3) {
            state.enqueue(id: i, units: 10, lane: .interactive, deadline: .seconds(1_000))
            let t = state.pump(now: now).admitted[0]
            now += state.rateLimited(t, retryAfter: nil, jitter: 0, now: now)
        }
        #expect(state.scale == 0.25)                         // 0.5, 0.25, then the floor
        let lastStrike = Duration.seconds(3)                 // strikes at 0, 1 and 3 s
        _ = state.pump(now: lastStrike + .seconds(59))
        #expect(state.scale == 0.25)
        _ = state.pump(now: lastStrike + .seconds(60))
        #expect(state.scale == 0.5)
        _ = state.pump(now: lastStrike + .seconds(120))
        #expect(state.scale == 0.75)
        _ = state.pump(now: lastStrike + .seconds(600))
        #expect(state.scale == 1)
    }

    @Test func scaledCeilingLimitsAdmission() {
        var state = GmailQuotaState(policy: policy)
        state.enqueue(id: 0, units: 10, lane: .background, deadline: .seconds(1_000))
        let t = state.pump(now: .zero).admitted[0]
        _ = state.rateLimited(t, retryAfter: nil, jitter: 0, now: .zero)
        // A half-open probe goes alone, so drain one at a time.
        enqueue(&state, 200, from: 1, lane: .background, deadline: .seconds(1_000))
        let (admitted, _) = drain(&state, now: .seconds(1))
        // Scale 0.5 → background limit 3,750; 10 units already charged.
        #expect(admitted.count == (3_750 - 10) / 40)
    }

    @Test func strikesResetAfterQuietWindow() {
        var state = GmailQuotaState(policy: policy)
        state.enqueue(id: 0, units: 10, lane: .interactive, deadline: .seconds(1_000))
        _ = state.rateLimited(state.pump(now: .zero).admitted[0], retryAfter: nil, jitter: 0, now: .zero)
        state.enqueue(id: 1, units: 10, lane: .interactive, deadline: .seconds(1_000))
        let probe = state.pump(now: .seconds(1)).admitted[0]
        state.finished(probe, gotHTTPResponse: true, now: .seconds(61))
        #expect(state.strikes == 0)
    }

    /// A waiter blocked only by a request in flight (half-open probe or the in-flight cap) still
    /// needs a timer for its own deadline: the request may take minutes (uploads, attachments).
    @Test func halfOpenWaitWakesAtTheWaitersDeadline() {
        var state = GmailQuotaState(policy: policy)
        enqueue(&state, 2, lane: .interactive)
        let tickets = state.pump(now: .zero).admitted
        _ = state.rateLimited(tickets[1], retryAfter: nil, jitter: 0, now: .zero)   // tickets[0] is still out
        state.enqueue(id: 9, units: 10, lane: .interactive, deadline: .seconds(91))
        let blocked = state.pump(now: .seconds(2))
        #expect(blocked.admitted.isEmpty)
        #expect(blocked.wakeAt == nil)                              // nothing but time…
        #expect(blocked.expiryAt == .seconds(91))                   // …for the deadline
        let late = state.pump(now: .seconds(91))
        #expect(late.expired == [9])
    }

    @Test func inFlightCapWaitWakesAtTheWaitersDeadline() {
        var state = GmailQuotaState(policy: GmailQuotaPolicy(maxInFlight: 1))
        state.enqueue(id: 1, units: 10, lane: .interactive, deadline: .seconds(90))
        state.enqueue(id: 2, units: 10, lane: .interactive, deadline: .seconds(30))
        let pump = state.pump(now: .zero)
        #expect(pump.admitted.map(\.id) == [1])
        #expect(pump.expiryAt == .seconds(30))
    }
}
