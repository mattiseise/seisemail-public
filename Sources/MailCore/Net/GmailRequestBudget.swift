import Foundation
import Synchronization

/// One logical Gmail request's 90 s deadline and rate-limited attempts (D6). `LiveGmailClient.perform`
/// opens one per call, so its own 401 and 5xx resends share them instead of starting over.
final class GmailRequestBudget: Sendable {
    @TaskLocal static var current: GmailRequestBudget?

    private struct State {
        var deadline: Duration?
        var clock: (any QuotaClock)?
        var rateLimitedAttempts = 0
    }

    private let state = Mutex(State())

    /// Fixed by the first send that asks; later sends get the same deadline.
    func deadline(clock: any QuotaClock, length: Duration) -> Duration {
        state.withLock { s in
            if let deadline = s.deadline { return deadline }
            let deadline = clock.now + length
            s.deadline = deadline
            s.clock = clock
            return deadline
        }
    }

    /// Counts one rate-limited send and returns the total so far.
    func recordRateLimited() -> Int {
        state.withLock { s in
            s.rateLimitedAttempts += 1
            return s.rateLimitedAttempts
        }
    }

    /// The deadline has passed: resending would only fail in the quota queue.
    var isSpent: Bool {
        let (deadline, clock) = state.withLock { ($0.deadline, $0.clock) }
        guard let deadline, let clock else { return false }
        return clock.now >= deadline
    }
}
