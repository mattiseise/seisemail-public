import Foundation
import Testing
@testable import MailCore

@Suite struct GmailQuotaTransportTests {
    let tokens = FakeTokens()
    let performSleeps = Counter()

    func client(_ stub: HeaderStubTransport, clock: any QuotaClock, policy: GmailQuotaPolicy = .macApp) -> LiveGmailClient {
        let sleeps = performSleeps
        let quota = GmailQuotaTransport(base: stub, policy: policy, clock: clock)
        return LiveGmailClient(auth: tokens, transport: quota,
                               retry: RetryPolicy(delays: [.milliseconds(500), .seconds(1), .seconds(2)], sleep: { _ in sleeps.increment() }))
    }

    static func incident() throws -> HeaderStubTransport.Reply {
        HeaderStubTransport.Reply(status: 403, body: try Fixture.data("gmail_403_rate_limit"))
    }

    static let ok = HeaderStubTransport.Reply(status: 200, body: Data("{}".utf8))

    @Test func incident403RetriedThenModifySucceeds() async throws {
        let clock = SkipAheadQuotaClock()
        let incident = try Self.incident()
        let stub = HeaderStubTransport(clock: clock) { _, i in i < 2 ? incident : Self.ok }
        try await client(stub, clock: clock).modify(threadID: "t1", add: [], remove: [GmailLabel.inbox])
        let log = stub.log
        #expect(log.count == 3)
        #expect(log[1].at - log[0].at >= .seconds(1))
        #expect(log[2].at - log[1].at >= .seconds(1))
        #expect(performSleeps.count == 0)
    }

    @Test func permission403SentOnce() async throws {
        let clock = SkipAheadQuotaClock()
        let body = try Fixture.data("gmail_403_insufficient_permissions")
        let stub = HeaderStubTransport(clock: clock) { _, _ in .init(status: 403, body: body) }
        do {
            try await client(stub, clock: clock).modify(threadID: "t1", add: [], remove: [GmailLabel.inbox])
            Issue.record("expected an error")
        } catch let GmailError.http(status, _) {
            #expect(status == 403)
        }
        #expect(stub.count == 1)
    }

    @Test func alwaysRateLimitedGivesUp() async throws {
        let clock = SkipAheadQuotaClock()
        let incident = try Self.incident()
        let stub = HeaderStubTransport(clock: clock) { _, _ in incident }
        await #expect(throws: GmailError.rateLimited) {
            try await client(stub, clock: clock).modify(threadID: "t1", add: [], remove: [GmailLabel.inbox])
        }
        #expect(stub.count == 7)
        let last = try #require(stub.log.last).at
        #expect(last >= .seconds(63) && last <= .seconds(69))
    }

    @Test func givesUpAtTheDeadlineBeforeMaxAttempts() async throws {
        let clock = SkipAheadQuotaClock()
        let stub = HeaderStubTransport(clock: clock) { _, _ in .init(status: 429, headers: ["Retry-After": "40"]) }
        await #expect(throws: GmailError.rateLimited) {
            try await client(stub, clock: clock).modify(threadID: "t1", add: [], remove: [])
        }
        #expect(stub.count == 3)                                  // 0 s, 40 s, 80 s; 120 s is past 90 s
        #expect(clock.now <= .seconds(90))
    }

    @Test func retryAfterHonoured() async throws {
        let clock = SkipAheadQuotaClock()
        let stub = HeaderStubTransport(clock: clock) { _, i in i == 0 ? .init(status: 429, headers: ["Retry-After": "9"]) : Self.ok }
        try await client(stub, clock: clock).modify(threadID: "t1", add: [], remove: [])
        #expect(stub.count == 2)
        #expect(stub.log[1].at >= .seconds(9))
    }

    @Test func sharedCooldownPausesParallelRequestsThenOneProbe() async throws {
        let clock = ManualQuotaClock()
        let incident = try Self.incident()
        let metadata = try Fixture.data("thread_metadata")
        let stub = HeaderStubTransport(clock: clock) { _, i in i < 6 ? incident : .init(status: 200, body: metadata) }
        let api = client(stub, clock: clock)
        stub.hold()
        let calls = (0..<10).map { i in Task { try await api.threadSummary(id: "t\(i)", me: nil) } }
        #expect(await eventually { stub.heldCount == 6 })         // background lane: 6 in flight
        stub.releaseAll()
        // All six come back 403; only the first is a strike, so the cooldown is 1 s.
        #expect(await eventually { clock.nextDeadline == .seconds(1) })
        #expect(stub.count == 6)
        stub.hold()
        clock.advance(to: .seconds(1))
        #expect(await eventually { stub.heldCount == 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(stub.count == 7)                                  // exactly one probe
        stub.releaseAll()
        for call in calls { _ = try await call.value }
        #expect(stub.count == 16)
        #expect(stub.peakInFlight <= 6)
    }

    @Test func noDoubleRetryWithPerform429() async throws {
        let clock = SkipAheadQuotaClock()
        let stub = HeaderStubTransport(clock: clock) { _, _ in .init(status: 429) }
        await #expect(throws: GmailError.rateLimited) {
            try await client(stub, clock: clock).modify(threadID: "t1", add: [], remove: [])
        }
        #expect(stub.count == 7)
        #expect(performSleeps.count == 0)
    }

    @Test func serverErrorsStillRetriedByPerform() async throws {
        let clock = SkipAheadQuotaClock()
        let stub = HeaderStubTransport(clock: clock) { _, i in i < 2 ? .init(status: 503) : Self.ok }
        try await client(stub, clock: clock).modify(threadID: "t1", add: [], remove: [])
        #expect(stub.count == 3)
        #expect(performSleeps.count == 2)
    }

    /// D6 is per logical request: perform's own 5xx resends share the 90 s and the 7 attempts.
    func clientAdvancingOnPerformSleep(_ stub: HeaderStubTransport, clock: SkipAheadQuotaClock) -> LiveGmailClient {
        LiveGmailClient(auth: tokens, transport: GmailQuotaTransport(base: stub, policy: .macApp, clock: clock),
                        retry: RetryPolicy(delays: [.milliseconds(500), .seconds(1), .seconds(2)], sleep: { clock.advance(by: $0) }))
    }

    @Test func serverErrorResendsShareTheAttemptBudget() async throws {
        let clock = SkipAheadQuotaClock()
        let incident = try Self.incident()
        let stub = HeaderStubTransport(clock: clock) { _, i in i % 7 < 6 ? incident : .init(status: 503) }
        await #expect(throws: GmailError.rateLimited) {
            try await clientAdvancingOnPerformSleep(stub, clock: clock).modify(threadID: "t1", add: [], remove: [])
        }
        let rateLimitedSends = (0..<stub.count).filter { $0 % 7 < 6 }.count
        #expect(rateLimitedSends <= 7)
        #expect(clock.now <= .seconds(90))
    }

    @Test func serverErrorResendsShareTheDeadline() async throws {
        let clock = SkipAheadQuotaClock()
        let stub = HeaderStubTransport(clock: clock) { _, i in
            i % 3 == 2 ? .init(status: 503) : .init(status: 429, headers: ["Retry-After": "40"])
        }
        await #expect(throws: (any Error).self) {
            try await clientAdvancingOnPerformSleep(stub, clock: clock).modify(threadID: "t1", add: [], remove: [])
        }
        #expect(try #require(stub.log.last).at <= .seconds(90))
        #expect(clock.now <= .seconds(90))
    }

    @Test func sendRetriedOnceOnRateLimitThenAcceptedOnce() async throws {
        let clock = SkipAheadQuotaClock()
        let incident = try Self.incident()
        let stub = HeaderStubTransport(clock: clock) { _, i in i == 0 ? incident : Self.ok }
        try await client(stub, clock: clock).send(raw: Data("raw".utf8), threadID: nil)
        #expect(stub.count == 2)
        #expect(stub.log.allSatisfy { $0.request.url?.path() == "/upload/gmail/v1/users/me/messages/send" })
    }

    @Test func cancelWhileQueuedThrowsURLErrorCancelled() async throws {
        let clock = ManualQuotaClock()
        let incident = try Self.incident()
        let stub = HeaderStubTransport(clock: clock) { _, _ in incident }
        let api = client(stub, clock: clock)
        let call = Task { try await api.modify(threadID: "t1", add: [], remove: []) }
        #expect(await eventually { clock.nextDeadline == .seconds(1) })   // waiting out the cooldown
        call.cancel()
        do {
            try await call.value
            Issue.record("expected cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(stub.count == 1)
    }

    @Test func unmeteredPassThrough() async throws {
        let clock = SkipAheadQuotaClock()
        let stub = HeaderStubTransport(clock: clock) { _, _ in .init(status: 429) }
        let quota = GmailQuotaTransport(base: stub, clock: clock)
        var token = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        token.httpMethod = "POST"
        let (_, response) = try await quota.send(token)
        #expect(response.statusCode == 429)
        #expect(stub.count == 1)
        #expect(await quota.scheduler.snapshot.windowUnits == 0)
    }
}
