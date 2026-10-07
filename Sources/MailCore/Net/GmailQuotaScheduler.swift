import Foundation

/// The async shell around `GmailQuotaState`: parks callers until admitted, fails them when their
/// deadline passes and keeps a single wake-up timer. One per account.
actor GmailQuotaScheduler {
    struct Snapshot: Sendable, Equatable {
        var windowUnits: Int
        var inFlight: Int
        var queued: Int
        var strikes: Int
        var scale: Double
        var cooldownRemaining: Duration
    }

    private var state: GmailQuotaState
    private let clock: any QuotaClock
    private var waiters: [UInt64: CheckedContinuation<GmailQuotaState.Ticket, any Error>] = [:]
    private var nextID: UInt64 = 0
    private var armedAt: Duration?
    private var armedExpiryAt: Duration?

    init(policy: GmailQuotaPolicy, clock: any QuotaClock) {
        self.state = GmailQuotaState(policy: policy)
        self.clock = clock
    }

    /// Waits for admission. Throws `GmailError.rateLimited` if `deadline` passes first (the request
    /// is then neither sent nor charged) and `URLError(.cancelled)` if the task is cancelled while
    /// queued, the same error URLSession throws.
    func acquire(units: Int, lane: GmailLane, deadline: Duration) async throws -> GmailQuotaState.Ticket {
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: URLError(.cancelled))
                    return
                }
                waiters[id] = continuation
                state.enqueue(id: id, units: units, lane: lane, deadline: deadline)
                pump()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func finished(_ ticket: GmailQuotaState.Ticket, gotHTTPResponse: Bool) {
        state.finished(ticket, gotHTTPResponse: gotHTTPResponse, now: clock.now)
        pump()
    }

    /// Returns when the shared cooldown ends, on the clock's timeline.
    func rateLimited(_ ticket: GmailQuotaState.Ticket, retryAfter: Duration?) -> Duration {
        let now = clock.now
        let remaining = state.rateLimited(ticket, retryAfter: retryAfter, jitter: clock.jitter(), now: now)
        pump()
        return now + remaining
    }

    var snapshot: Snapshot {
        let now = clock.now
        return Snapshot(
            windowUnits: state.windowUnits(now: now),
            inFlight: state.inFlight,
            queued: state.queued,
            strikes: state.strikes,
            scale: state.scale,
            cooldownRemaining: max(.zero, state.cooldownUntil - now)
        )
    }

    private func cancel(_ id: UInt64) {
        guard state.cancel(id: id) else { return }
        waiters.removeValue(forKey: id)?.resume(throwing: URLError(.cancelled))
        pump()
    }

    private func pump() {
        let result = state.pump(now: clock.now)
        for ticket in result.admitted {
            waiters.removeValue(forKey: ticket.id)?.resume(returning: ticket)
        }
        for id in result.expired {
            waiters.removeValue(forKey: id)?.resume(throwing: GmailError.rateLimited)
        }
        arm(result.wakeAt)
        armExpiry(result.expiryAt)
    }

    /// Keeps one timer for the earliest wake-up; a later timer that fires early just pumps again.
    private func arm(_ wakeAt: Duration?) {
        guard let wakeAt else { return }
        if let armedAt, armedAt <= wakeAt, armedAt > clock.now { return }
        armedAt = wakeAt
        let clock = self.clock
        Task { [weak self] in
            do { try await clock.sleep(until: wakeAt) } catch { return }
            await self?.wake(at: wakeAt)
        }
    }

    private func wake(at: Duration) {
        if armedAt == at { armedAt = nil }
        pump()
    }

    /// A second, deadline-only timer for waiters held up by requests in flight.
    private func armExpiry(_ expiryAt: Duration?) {
        guard let expiryAt else { return }
        if let armedExpiryAt, armedExpiryAt <= expiryAt, armedExpiryAt > clock.now { return }
        armedExpiryAt = expiryAt
        let clock = self.clock
        Task { [weak self] in
            do { try await clock.sleepForDeadline(until: expiryAt) } catch { return }
            await self?.expire(at: expiryAt)
        }
    }

    private func expire(at: Duration) {
        if armedExpiryAt == at { armedExpiryAt = nil }
        pump()
    }
}
