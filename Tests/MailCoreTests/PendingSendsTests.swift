import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct PendingSendsTests {
    final class Log { var sent: [UUID] = []; var failed: [UUID] = [] }

    func make(elapses: Bool, failing: Bool = false, log: Log) -> PendingSends {
        PendingSends(
            sleep: { d in if !elapses { try await Task.sleep(for: .seconds(3600)) } },
            send: { draft in
                if failing { throw GmailError.offline }
                log.sent.append(draft.id)
            },
            onFailure: { draft, _ in log.failed.append(draft.id) }
        )
    }

    @Test func sendsAfterDelay() async throws {
        let log = Log()
        let p = make(elapses: true, log: log)
        let d = Draft(body: "a")
        try await p.enqueue(d, delaySeconds: 10)
        await p.settle()
        #expect(log.sent == [d.id])
        #expect(p.items.isEmpty)
    }

    @Test func cancelReturnsDraftAndNothingIsSent() async throws {
        let log = Log()
        let p = make(elapses: false, log: log)
        let d = Draft(body: "a")
        try await p.enqueue(d, delaySeconds: 10)
        #expect(p.items.map(\.id) == [d.id])
        #expect(p.cancel(id: d.id) == d)
        await p.settle()
        #expect(log.sent.isEmpty)
        #expect(p.items.isEmpty)
    }

    @Test func cancelAfterSendReturnsNil() async throws {
        let log = Log()
        let p = make(elapses: true, log: log)
        let d = Draft(body: "a")
        try await p.enqueue(d, delaySeconds: 10)
        await p.settle()
        #expect(p.cancel(id: d.id) == nil)
        #expect(log.sent == [d.id])
    }

    @Test func flushSendsEverythingNowOnce() async throws {
        let log = Log()
        let p = make(elapses: false, log: log)
        let a = Draft(body: "a"), b = Draft(body: "b")
        try await p.enqueue(a, delaySeconds: 20)
        try await p.enqueue(b, delaySeconds: 20)
        _ = await p.flush()
        await p.settle()
        #expect(log.sent == [a.id, b.id])
        #expect(p.items.isEmpty)
    }

    @Test func zeroDelaySendsImmediatelyAndThrows() async {
        let log = Log()
        let p = make(elapses: false, failing: true, log: log)
        await #expect(throws: GmailError.offline) { try await p.enqueue(Draft(), delaySeconds: 0) }
        #expect(p.items.isEmpty)
        #expect(log.failed.isEmpty)
    }

    @Test func delayedFailureIsReported() async throws {
        let log = Log()
        let p = make(elapses: true, failing: true, log: log)
        let d = Draft(body: "a")
        try await p.enqueue(d, delaySeconds: 10)
        await p.settle()
        #expect(log.failed == [d.id])
        #expect(p.items.isEmpty)
    }

    @Test func flushReturnsFailuresInsteadOfReporting() async throws {
        let log = Log()
        let p = make(elapses: false, failing: true, log: log)
        let d = Draft(body: "a")
        try await p.enqueue(d, delaySeconds: 10)
        let failed = await p.flush()
        #expect(failed.map(\.id) == [d.id])
        #expect(log.failed.isEmpty)
    }

    @Test func flushWaitsForSendAlreadyInFlight() async throws {
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        let p = PendingSends(
            sleep: { _ in },
            send: { draft in
                for await _ in gate.stream { break }
                log.sent.append(draft.id)
            },
            onFailure: { draft, _ in log.failed.append(draft.id) }
        )
        let d = Draft(body: "a")
        try await p.enqueue(d, delaySeconds: 10)
        while !p.isSending { await Task.yield() }
        #expect(p.items.isEmpty)
        async let flushed = p.flush()
        gate.continuation.yield()
        _ = await flushed
        #expect(log.sent == [d.id])
    }
}
