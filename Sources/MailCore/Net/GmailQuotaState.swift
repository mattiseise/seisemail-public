import Foundation

/// The quota scheduler's pure core: a sliding-window ledger of admitted units, two FIFO lanes,
/// in-flight limits and one shared cooldown with a half-open probe. No clock, no async: every
/// call takes `now`, which keeps it deterministic in tests.
struct GmailQuotaState: Sendable {
    struct Ticket: Sendable, Hashable {
        let id: UInt64
        let units: Int
        let lane: GmailLane
        /// The strike count when admitted; only a rate limit on a current ticket escalates.
        let epoch: UInt64
    }

    struct Pump: Sendable {
        var admitted: [Ticket] = []
        /// Waiters whose deadline passed while queued: never sent, never charged.
        var expired: [UInt64] = []
        /// When time unblocks the queue (cooldown, window, or a deadline when nothing is in flight).
        var wakeAt: Duration?
        /// The earliest queued deadline before `wakeAt`, while the queue waits on requests in
        /// flight; those may take minutes (uploads, attachments) and the deadline includes queueing.
        var expiryAt: Duration?
    }

    private struct Waiter: Sendable {
        let id: UInt64
        let units: Int
        let lane: GmailLane
        let deadline: Duration
    }

    private struct Charge: Sendable {
        let at: Duration
        let units: Int
    }

    let policy: GmailQuotaPolicy
    private var ledger: [Charge] = []
    private var interactive: [Waiter] = []
    private var background: [Waiter] = []
    private(set) var inFlight = 0
    private(set) var backgroundInFlight = 0
    private(set) var epoch: UInt64 = 0
    private(set) var strikes = 0
    private(set) var scale = 1.0
    private var scaleAtStrike = 1.0
    private var lastStrikeAt: Duration?
    private(set) var cooldownUntil: Duration = .zero
    private(set) var halfOpen = false

    init(policy: GmailQuotaPolicy) {
        self.policy = policy
    }

    var queued: Int { interactive.count + background.count }

    mutating func enqueue(id: UInt64, units: Int, lane: GmailLane, deadline: Duration) {
        let waiter = Waiter(id: id, units: units, lane: lane, deadline: deadline)
        switch lane {
        case .interactive: interactive.append(waiter)
        case .background: background.append(waiter)
        }
    }

    /// True when the waiter was still queued (so it was never charged).
    mutating func cancel(id: UInt64) -> Bool {
        if let i = interactive.firstIndex(where: { $0.id == id }) {
            interactive.remove(at: i)
            return true
        }
        if let i = background.firstIndex(where: { $0.id == id }) {
            background.remove(at: i)
            return true
        }
        return false
    }

    func windowUnits(now: Duration) -> Int {
        ledger.reduce(0) { $1.at + policy.window > now ? $0 + $1.units : $0 }
    }

    mutating func pump(now: Duration) -> Pump {
        var out = Pump()
        ledger.removeAll { $0.at + policy.window <= now }
        var sum = ledger.reduce(0) { $0 + $1.units }
        recoverScale(now: now)

        for lane in [GmailLane.interactive, .background] {
            let (keep, gone) = partitionExpired(lane == .interactive ? interactive : background, now: now)
            if lane == .interactive { interactive = keep } else { background = keep }
            out.expired += gone.map(\.id)
        }

        // Only time can unblock a cooldown or a full window; a wait on in-flight requests ends
        // when one finishes, which pumps again.
        var waitingOnTime = false
        if now < cooldownUntil {
            waitingOnTime = queued > 0
            if waitingOnTime { out.wakeAt = cooldownUntil }
        } else {
            // Strict priority: the background lane only moves when no interactive request waits.
            while let head = interactive.first ?? background.first {
                if halfOpen, inFlight > 0 { break }
                if inFlight >= policy.maxInFlight { break }
                if head.lane == .background, backgroundInFlight >= policy.maxBackgroundInFlight { break }
                let ceiling = head.lane == .interactive ? policy.ceiling : policy.backgroundCeiling
                let limit = Int(Double(ceiling) * scale)
                // An empty window admits anything, so a request bigger than the limit can't deadlock.
                guard sum + head.units <= limit || sum == 0 else {
                    var freed = 0
                    for (i, charge) in ledger.enumerated() {
                        freed += charge.units
                        if sum + head.units - freed <= limit || i == ledger.count - 1 {
                            out.wakeAt = charge.at + policy.window
                            break
                        }
                    }
                    waitingOnTime = true
                    break
                }
                if head.lane == .interactive { interactive.removeFirst() } else { background.removeFirst() }
                ledger.append(Charge(at: now, units: head.units))
                sum += head.units
                inFlight += 1
                if head.lane == .background { backgroundInFlight += 1 }
                out.admitted.append(Ticket(id: head.id, units: head.units, lane: head.lane, epoch: epoch))
                if halfOpen { break }
            }
        }

        // Every queued deadline gets a timer, whatever the wait is for (spec section 7, step 6).
        if let earliest = (interactive + background).map(\.deadline).min() {
            if waitingOnTime || inFlight == 0 {
                out.wakeAt = min(out.wakeAt ?? earliest, earliest)
            } else if earliest < out.wakeAt ?? .seconds(Int64.max) {
                out.expiryAt = earliest
            }
        }
        return out
    }

    /// A request got an answer (`gotHTTPResponse`) or failed in transport.
    mutating func finished(_ t: Ticket, gotHTTPResponse: Bool, now: Duration) {
        release(t)
        // Only a request admitted after the latest strike proves the gate can open again.
        if gotHTTPResponse, t.epoch == epoch { halfOpen = false }
        resetStrikesIfQuiet(now: now)
    }

    /// Gmail rate limited `t`. Returns how long the shared cooldown still runs.
    mutating func rateLimited(_ t: Ticket, retryAfter: Duration?, jitter: Double, now: Duration) -> Duration {
        if t.epoch == epoch {
            resetStrikesIfQuiet(now: now)
            recoverScale(now: now)
            strikes += 1
            epoch += 1
            scaleAtStrike = max(policy.minScale, scale / 2)
            scale = scaleAtStrike
            lastStrikeAt = now
            // Google's own backoff: min(2^n s, cap) + up to 1 s of jitter; a longer Retry-After wins.
            let exponential = min(Duration.seconds(1) * (1 << min(strikes - 1, 20)), policy.backoffCap)
            var delay = exponential + .seconds(jitter)
            if let retryAfter { delay = max(delay, min(retryAfter, policy.retryAfterCap)) }
            cooldownUntil = max(cooldownUntil, now + delay)
            halfOpen = true
        }
        release(t)
        return max(.zero, cooldownUntil - now)
    }

    // MARK: - Helpers

    private mutating func release(_ t: Ticket) {
        inFlight = max(0, inFlight - 1)
        if t.lane == .background { backgroundInFlight = max(0, backgroundInFlight - 1) }
    }

    private mutating func resetStrikesIfQuiet(now: Duration) {
        if let last = lastStrikeAt, now - last >= policy.window { strikes = 0 }
    }

    /// The ceilings grow back by 0.25 for every full window without a strike.
    private mutating func recoverScale(now: Duration) {
        guard let last = lastStrikeAt else { return }
        let quietWindows = max(0, ((now - last) / policy.window).rounded(.down))
        scale = min(1, scaleAtStrike + 0.25 * quietWindows)
    }

    private func partitionExpired(_ queue: [Waiter], now: Duration) -> (keep: [Waiter], gone: [Waiter]) {
        var keep: [Waiter] = []
        var gone: [Waiter] = []
        for waiter in queue {
            if waiter.deadline <= now { gone.append(waiter) } else { keep.append(waiter) }
        }
        return (keep, gone)
    }
}
