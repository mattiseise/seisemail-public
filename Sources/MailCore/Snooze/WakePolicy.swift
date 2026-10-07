import Foundation

/// What one client wake pass came to, for the loop's next delay and the app's reaction.
public enum WakeOutcome: Sendable, Equatable {
    case completed(woken: Int, cancelled: Int, nextWakeAt: Date?)
    /// WakeReport.skipped
    case skipped
    /// Expired sign-in: nothing ran.
    case paused
    /// GmailError.offline
    case offline
    /// GmailError.rateLimited: the quota transport waited out Gmail's limit and gave up.
    case rateLimited
    /// AuthError.invalidGrant / .notSignedIn (the same rule as MailStore's error handling)
    case signInExpired
    /// Anything else.
    case failed
    /// Cancellation, or the result was dropped (detached / rebuilt).
    case cancelled

    /// skipped → .skipped; else .completed(woken.count, cancelled.count, nextWakeAt)
    public init(report: WakeReport) {
        self = report.skipped
            ? .skipped
            : .completed(woken: report.woken.count, cancelled: report.cancelled.count, nextWakeAt: report.nextWakeAt)
    }

    /// CancellationError or URLError(.cancelled) → .cancelled; offline → .offline; rate limited → .rateLimited;
    /// expired sign-in → .signInExpired; anything else → .failed.
    public init(error: any Error) {
        if GmailFailure.isCancellation(error) {
            self = .cancelled
        } else if let e = error as? GmailError, e == .offline {
            self = .offline
        } else if GmailFailure.isRateLimited(error) {
            self = .rateLimited
        } else if let e = error as? AuthError, e == .invalidGrant || e == .notSignedIn {
            self = .signInExpired
        } else {
            self = .failed
        }
    }
}

/// When the next client pass runs (conventions §1: at launch and every 5 min).
public struct WakePolicy: Sendable, Equatable {
    public var interval: TimeInterval = 300
    public var offlineRetry: TimeInterval = 60
    /// Owner decision Q4: also look again at the report's nextWakeAt, at least `minimumGap` later. Off = contract as written.
    public var followsNextWake = false
    public var minimumGap: TimeInterval = 60

    public init(interval: TimeInterval = 300, offlineRetry: TimeInterval = 60,
                followsNextWake: Bool = false, minimumGap: TimeInterval = 60) {
        self.interval = interval
        self.offlineRetry = offlineRetry
        self.followsNextWake = followsNextWake
        self.minimumGap = minimumGap
    }

    /// .offline, .rateLimited → offlineRetry; .completed with a nextWakeAt and followsNextWake →
    /// min(interval, max(minimumGap, nextWakeAt − now)); everything else → interval.
    public func delay(after outcome: WakeOutcome, now: Date) -> TimeInterval {
        switch outcome {
        case .offline, .rateLimited:
            return offlineRetry
        case .completed(_, _, let next?) where followsNextWake:
            return min(interval, max(minimumGap, next.timeIntervalSince(now)))
        default:
            return interval
        }
    }
}
