import Foundation

/// Builds the per-account Gmail transport stack:
/// `LiveGmailClient → GmailReadCacheTransport → GmailQuotaTransport → URLSessionTransport`.
public enum GmailTransports {
    /// One per account, never shared: the quota and the cache are both per user. The cache sits
    /// outside, so hits never consume quota.
    public static func live(policy: GmailQuotaPolicy = .macApp) -> any HTTPTransport {
        live(policy: policy, base: URLSessionTransport())
    }

    /// The same stack over another base layer: the daemon puts its probe (clock skew, unit meter)
    /// under the quota transport, so it sees every send including retries.
    public static func live(policy: GmailQuotaPolicy, base: any HTTPTransport) -> any HTTPTransport {
        make(base: base, policy: policy, clock: SystemQuotaClock())
    }

    static func make(base: any HTTPTransport, policy: GmailQuotaPolicy, clock: any QuotaClock,
                     cache: GmailReadCache.Policy = .init()) -> any HTTPTransport {
        GmailReadCacheTransport(
            base: GmailQuotaTransport(base: base, policy: policy, clock: clock),
            clock: clock,
            policy: cache
        )
    }
}
