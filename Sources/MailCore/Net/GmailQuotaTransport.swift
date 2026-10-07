import Foundation
import os

private let log = Logger(subsystem: "fi.mak8r.mail", category: "quota")

/// Paces Gmail requests under this client's share of the per-user quota and waits out Gmail's
/// rate limits with one shared cooldown. A request that is still rate limited after
/// `maxAttempts` sends or `requestDeadline` throws `GmailError.rateLimited`; every other answer,
/// including permission 403s, 401s and 5xx, goes back to `LiveGmailClient.perform` unchanged.
/// Both limits belong to the logical request (`GmailRequestBudget`), not to one `send`.
public struct GmailQuotaTransport: HTTPTransport {
    let base: any HTTPTransport
    let policy: GmailQuotaPolicy
    let clock: any QuotaClock
    let scheduler: GmailQuotaScheduler

    public init(base: any HTTPTransport, policy: GmailQuotaPolicy = .macApp, clock: any QuotaClock = SystemQuotaClock()) {
        self.base = base
        self.policy = policy
        self.clock = clock
        self.scheduler = GmailQuotaScheduler(policy: policy, clock: clock)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint = GmailEndpoint(request) else { return try await base.send(request) }
        // perform's 401 and 5xx resends come back here with the same budget (D6 is per request).
        let budget = GmailRequestBudget.current ?? GmailRequestBudget()
        let deadline = budget.deadline(clock: clock, length: policy.requestDeadline)
        while true {
            let ticket = try await scheduler.acquire(units: endpoint.units, lane: endpoint.lane, deadline: deadline)
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await base.send(request)
            } catch {
                await scheduler.finished(ticket, gotHTTPResponse: false)
                throw error
            }
            switch GmailRateLimit.classify(response, body: data, now: clock.wallNow) {
            case .notRateLimited:
                await scheduler.finished(ticket, gotHTTPResponse: true)
                return (data, response)
            case .rateLimited(let retryAfter, let reason, let quotaLimit):
                let attempts = budget.recordRateLimited()
                let cooldownEnd = await scheduler.rateLimited(ticket, retryAfter: retryAfter)
                let snapshot = await scheduler.snapshot
                let kind = String(describing: endpoint.kind).prefix(40)
                log.error("rate limited \(response.statusCode, privacy: .public) \(kind, privacy: .public) reason=\(reason ?? "-", privacy: .public) quota_limit=\(quotaLimit ?? "-", privacy: .public) window=\(snapshot.windowUnits, privacy: .public) strike=\(snapshot.strikes, privacy: .public) cooldown=\(snapshot.cooldownRemaining.components.seconds, privacy: .public)s attempt=\(attempts, privacy: .public)")
                if attempts >= policy.maxAttempts || cooldownEnd >= deadline {
                    log.error("giving up \(kind, privacy: .public) after \(attempts, privacy: .public) attempts")
                    throw GmailError.rateLimited
                }
            }
        }
    }
}
