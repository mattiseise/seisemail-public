import Foundation

/// How much of Gmail's per-user quota one client may use, and how long it waits when Gmail says no.
/// Every client of the same Google project shares the per-user limit, so each takes a share of it.
public struct GmailQuotaPolicy: Sendable, Equatable {
    /// Gmail's "Units per minute per user" for the seisemail project (raised to 15,000 on 2026-10-04;
    /// new projects get 6,000). Change it only after the Cloud console shows the new value.
    public var perUserLimit: Int
    /// This client's share of `perUserLimit`; the total ceiling.
    public var share: Double
    /// The share background traffic (lists, rows, counts, polling) may use; the rest is kept for the user.
    public var backgroundShare: Double
    /// Google's rolling window.
    public var window: Duration
    public var maxInFlight: Int
    public var maxBackgroundInFlight: Int
    /// Sends per request, including the first, before giving up with `GmailError.rateLimited`.
    public var maxAttempts: Int
    /// Covers both queueing and retries.
    public var requestDeadline: Duration
    public var backoffCap: Duration
    public var retryAfterCap: Duration
    /// The lowest the ceilings shrink to after repeated rate limits.
    public var minScale: Double

    public init(
        perUserLimit: Int = 15_000,
        share: Double = 0.70,
        backgroundShare: Double = 0.50,
        window: Duration = .seconds(60),
        maxInFlight: Int = 8,
        maxBackgroundInFlight: Int = 6,
        maxAttempts: Int = 7,
        requestDeadline: Duration = .seconds(90),
        backoffCap: Duration = .seconds(32),
        retryAfterCap: Duration = .seconds(60),
        minScale: Double = 0.25
    ) {
        self.perUserLimit = perUserLimit
        self.share = share
        self.backgroundShare = backgroundShare
        self.window = window
        self.maxInFlight = maxInFlight
        self.maxBackgroundInFlight = maxBackgroundInFlight
        self.maxAttempts = maxAttempts
        self.requestDeadline = requestDeadline
        self.backoffCap = backoffCap
        self.retryAfterCap = retryAfterCap
        self.minScale = minScale
    }

    /// The Mac app (and the iPhone and Windows apps): 70 % in total, 50 % for background traffic.
    public static let macApp = GmailQuotaPolicy()
    /// The Mac mini daemon: 20 %. Together with the Mac app 90 % of the per-user limit.
    public static let daemon = GmailQuotaPolicy(share: 0.20, backgroundShare: 0.20, maxInFlight: 4, maxBackgroundInFlight: 4)

    /// Units per window any request may use.
    var ceiling: Int { Int(Double(perUserLimit) * share) }
    /// Units per window background requests may use.
    var backgroundCeiling: Int { Int(Double(perUserLimit) * backgroundShare) }
}
