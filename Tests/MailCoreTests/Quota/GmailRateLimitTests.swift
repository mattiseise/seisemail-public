import Foundation
import Testing
@testable import MailCore

@Suite struct GmailRateLimitTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func classify(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> GmailRateLimit.Verdict {
        GmailRateLimit.classify(response(status, headers: headers), body: body, now: now)
    }

    @Test func incident403IsRateLimited() throws {
        let verdict = classify(403, try Fixture.data("gmail_403_rate_limit"))
        #expect(verdict == .rateLimited(retryAfter: nil, reason: "rateLimitExceeded", quotaLimit: "totalQueryCostPerMinutePerUser"))
    }

    @Test func userRateLimitExceededIsRateLimited() throws {
        let verdict = classify(403, try Fixture.data("gmail_403_user_rate_limit"))
        #expect(verdict == .rateLimited(retryAfter: nil, reason: "userRateLimitExceeded", quotaLimit: nil))
    }

    @Test func detailsReasonAloneIsRateLimited() {
        let body = json(["error": ["code": 403, "details": [["reason": "RATE_LIMIT_EXCEEDED"]]]])
        #expect(classify(403, body) == .rateLimited(retryAfter: nil, reason: "RATE_LIMIT_EXCEEDED", quotaLimit: nil))
    }

    @Test(arguments: ["", "<html><body>Too many</body></html>", #"{"error":{"code":429}}"#])
    func any429IsRateLimited(_ body: String) {
        guard case .rateLimited = classify(429, Data(body.utf8)) else {
            Issue.record("429 must count as rate limited")
            return
        }
    }

    @Test(arguments: ["gmail_403_daily_limit", "gmail_403_insufficient_permissions", "gmail_403_access_not_configured"])
    func otherForbiddenIsNotRateLimited(_ fixture: String) throws {
        #expect(classify(403, try Fixture.data(fixture)) == .notRateLimited)
    }

    @Test func plainForbiddenAndQuotaExceededAreNotRateLimited() {
        let forbidden = json(["error": ["code": 403, "errors": [["reason": "forbidden"]]]])
        let quota = json(["error": ["code": 403, "errors": [["reason": "quotaExceeded"]]]])
        let domain = json(["error": ["code": 403, "errors": [["reason": "domainPolicy"]]]])
        #expect(classify(403, forbidden) == .notRateLimited)
        #expect(classify(403, quota) == .notRateLimited)
        #expect(classify(403, domain) == .notRateLimited)
    }

    @Test func unparsable403NotRetried() {
        #expect(classify(403, Data("<html>Forbidden</html>".utf8)) == .notRateLimited)
        #expect(classify(403, Data()) == .notRateLimited)
    }

    @Test func nonJSONWithReasonTokenIsRateLimited() {
        let verdict = classify(403, Data("upstream said: userRateLimitExceeded, slow down".utf8))
        #expect(verdict == .rateLimited(retryAfter: nil, reason: "userRateLimitExceeded", quotaLimit: nil))
    }

    @Test func reasonBeyond2000BytesFound() {
        let body = json(["error": ["code": 403, "message": String(repeating: "x", count: 3_000),
                                   "errors": [["reason": "rateLimitExceeded"]]]])
        #expect(body.count > 2_000)
        guard case .rateLimited = classify(403, body) else {
            Issue.record("the reason past 2,000 bytes was missed")
            return
        }
    }

    @Test func otherStatusesAreNotRateLimited() {
        let body = json(["error": ["errors": [["reason": "rateLimitExceeded"]]]])
        #expect(classify(500, body) == .notRateLimited)
        #expect(classify(401, body) == .notRateLimited)
        #expect(classify(200, body) == .notRateLimited)
    }

    @Test func retryAfterHeaderIsCarried() throws {
        let verdict = classify(429, Data(), headers: ["Retry-After": "9"])
        #expect(verdict == .rateLimited(retryAfter: .seconds(9), reason: nil, quotaLimit: nil))
    }

    @Test func retryAfter() {
        let cap = Duration.seconds(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let in12 = formatter.string(from: now.addingTimeInterval(12))
        #expect(GmailRateLimit.retryAfter("7", now: now, cap: cap) == .seconds(7))
        #expect(GmailRateLimit.retryAfter(in12, now: now, cap: cap) == .seconds(12))
        #expect(GmailRateLimit.retryAfter("3600", now: now, cap: cap) == .seconds(60))
        #expect(GmailRateLimit.retryAfter("soon", now: now, cap: cap) == nil)
        #expect(GmailRateLimit.retryAfter("-1", now: now, cap: cap) == nil)
        #expect(GmailRateLimit.retryAfter("0", now: now, cap: cap) == nil)
        #expect(GmailRateLimit.retryAfter(nil, now: now, cap: cap) == nil)
    }
}
