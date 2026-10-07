import Foundation

/// Tells Gmail's short-term rate limits (worth waiting for) apart from every other 403.
enum GmailRateLimit {
    enum Verdict: Sendable, Equatable {
        case rateLimited(retryAfter: Duration?, reason: String?, quotaLimit: String?)
        case notRateLimited
    }

    /// `error.errors[].reason` values that mean "slow down".
    static let reasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded"]
    /// `error.details[].reason` (google.rpc.ErrorInfo) that means the same.
    static let detailReason = "RATE_LIMIT_EXCEEDED"
    static let retryAfterCap: Duration = .seconds(60)

    /// Rate limited: any 429; a 403 whose JSON reason is a rate limit; a non-JSON 403 that names one.
    /// Everything else, including daily limits, permission and configuration errors and 403s that
    /// can't be read, is not, so `LiveGmailClient.perform` reports it as before. Reads the full body.
    static func classify(_ response: HTTPURLResponse, body: Data, now: Date) -> Verdict {
        let status = response.statusCode
        guard status == 429 || status == 403 else { return .notRateLimited }
        let retry = retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now, cap: retryAfterCap)
        let parsed = parse(body)
        if status == 429 {
            return .rateLimited(retryAfter: retry, reason: parsed?.reason, quotaLimit: parsed?.quotaLimit)
        }
        if let parsed {
            return parsed.isRateLimit ? .rateLimited(retryAfter: retry, reason: parsed.reason, quotaLimit: parsed.quotaLimit) : .notRateLimited
        }
        // Not Google's JSON error shape: fall back to looking for the tokens.
        let text = String(decoding: body, as: UTF8.self)
        if let token = (Array(reasons).sorted() + [detailReason]).first(where: { text.contains($0) }) {
            return .rateLimited(retryAfter: retry, reason: token, quotaLimit: nil)
        }
        return .notRateLimited
    }

    /// Delta-seconds or an HTTP-date, clamped to `cap`. Zero, negative or unreadable values give nil.
    static func retryAfter(_ value: String?, now: Date, cap: Duration) -> Duration? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let seconds: Double
        if let delta = Int(raw) {
            seconds = Double(delta)
        } else if let date = httpDate(raw) {
            seconds = date.timeIntervalSince(now).rounded()
        } else {
            return nil
        }
        guard seconds > 0 else { return nil }
        return min(.seconds(seconds), cap)
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private struct Parsed {
        var isRateLimit: Bool
        var reason: String?
        var quotaLimit: String?
    }

    /// nil when the body is not `{"error": {…}}`.
    private static func parse(_ body: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        let errorReasons = (error["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        let details = error["details"] as? [[String: Any]] ?? []
        let detailReasons = details.compactMap { $0["reason"] as? String }
        let quotaLimit = details.lazy.compactMap { ($0["metadata"] as? [String: Any])?["quota_limit"] as? String }.first
        let hit = errorReasons.first(where: reasons.contains) ?? detailReasons.first { $0 == detailReason }
        return Parsed(isRateLimit: hit != nil, reason: hit ?? errorReasons.first ?? detailReasons.first, quotaLimit: quotaLimit)
    }
}
