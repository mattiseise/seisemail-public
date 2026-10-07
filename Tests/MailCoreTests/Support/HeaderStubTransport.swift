import Foundation
import Synchronization
@testable import MailCore

/// Scriptable transport with status, headers and body per request. Logs each request with the
/// clock's time, tracks the peak number of requests in flight and can hold requests until released.
final class HeaderStubTransport: HTTPTransport, Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    struct Entry: Sendable {
        var request: URLRequest
        var at: Duration
    }

    typealias Handler = @Sendable (URLRequest, _ index: Int) async throws -> Reply

    private struct State {
        var log: [Entry] = []
        var inFlight = 0
        var peakInFlight = 0
        var holding = false
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let clock: any QuotaClock
    private let handler: Handler
    private let state = Mutex(State())

    init(clock: any QuotaClock, _ handler: @escaping Handler) {
        self.clock = clock
        self.handler = handler
    }

    var log: [Entry] { state.withLock { $0.log } }
    var count: Int { state.withLock { $0.log.count } }
    var peakInFlight: Int { state.withLock { $0.peakInFlight } }
    var heldCount: Int { state.withLock { $0.held.count } }

    func hold() { state.withLock { $0.holding = true } }

    func releaseAll() {
        let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.holding = false
            defer { s.held = [] }
            return s.held
        }
        for c in held { c.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = state.withLock { s -> Int in
            s.log.append(Entry(request: request, at: clock.now))
            s.inFlight += 1
            s.peakInFlight = max(s.peakInFlight, s.inFlight)
            return s.log.count - 1
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let wait = state.withLock { s -> Bool in
                guard s.holding else { return false }
                s.held.append(c)
                return true
            }
            if !wait { c.resume() }
        }
        let reply = try await handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}
