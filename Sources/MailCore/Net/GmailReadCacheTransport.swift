import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "fi.mak8r.mail", category: "quota")

/// Serves unchanged thread rows from memory so they cost no quota. Sits outside the quota
/// transport: a hit never reaches the scheduler. Writes to a thread drop its rows before and
/// after the call. A message write (`batchModify`, `messages/{id}/…`) drops the threads that own
/// its messages, or everything when one of them is not in a stored body.
public final class GmailReadCacheTransport: HTTPTransport, Sendable {
    let base: any HTTPTransport
    private let clock: any QuotaClock
    private let state: Mutex<GmailReadCache>

    public convenience init(base: any HTTPTransport) {
        self.init(base: base, clock: SystemQuotaClock(), policy: .init())
    }

    init(base: any HTTPTransport, clock: any QuotaClock, policy: GmailReadCache.Policy) {
        self.base = base
        self.clock = clock
        self.state = Mutex(GmailReadCache(policy: policy))
    }

    var stats: (hits: Int, misses: Int) { state.withLock { $0.stats } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint = GmailEndpoint(request) else { return try await base.send(request) }
        switch endpoint.kind {
        case .threadGet(let id, let format):
            let cacheable = state.withLock { $0.policy.formats.contains(format) }
            guard cacheable, let url = request.url else { return try await base.send(request) }
            let key = "threads/\(id)?\(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")"
            let fresh = request.cachePolicy == .reloadIgnoringLocalCacheData
            let now = clock.now
            let (hit, seq, stats) = state.withLock { cache -> (Data?, UInt64, (hits: Int, misses: Int)) in
                (fresh ? nil : cache.lookup(threadID: id, key: key, now: now), cache.writeSeq, cache.stats)
            }
            if !fresh, (stats.hits + stats.misses) % 100 == 0 {
                log.debug("read cache hits=\(stats.hits, privacy: .public) misses=\(stats.misses, privacy: .public)")
            }
            if let hit {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                return (hit, response)
            }
            let (data, response) = try await base.send(request)
            if (200..<300).contains(response.statusCode) {
                let done = clock.now
                state.withLock { $0.store(threadID: id, key: key, body: data, startedAt: seq, now: done) }
            }
            return (data, response)

        case .threadList:
            let seq = state.withLock { $0.writeSeq }
            let (data, response) = try await base.send(request)
            if (200..<300).contains(response.statusCode) {
                let now = clock.now
                state.withLock { $0.observeList(data, startedAt: seq, now: now) }
            }
            return (data, response)

        case .threadWrite(let id):
            state.withLock { $0.invalidate(threadID: id, now: clock.now) }
            defer { state.withLock { $0.invalidate(threadID: id, now: clock.now) } }
            return try await base.send(request)

        case .messageWrite:
            let ids = Self.messageIDs(in: request)
            // Resolved once: after the first drop the bodies that map messages to threads are gone.
            let threads = state.withLock { cache in ids.flatMap { cache.threads(owning: $0) } }
            func drop() {
                let now = clock.now
                state.withLock { cache in
                    if let threads { cache.invalidate(threadIDs: threads, now: now) } else { cache.invalidateAll() }
                }
            }
            drop()
            defer { drop() }
            return try await base.send(request)

        case .labelWrite, .send, .other:
            return try await base.send(request)
        }
    }

    /// The message ids a `messages/batchModify` body or a `messages/{id}/…` path names.
    static func messageIDs(in request: URLRequest) -> [String]? {
        guard let path = request.url?.path(), let range = path.range(of: "/users/me/messages/") else { return nil }
        let rest = path[range.upperBound...].split(separator: "/")
        if rest == ["batchModify"] {
            guard let body = request.httpBody,
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let ids = root["ids"] as? [String], !ids.isEmpty else { return nil }
            return ids
        }
        return rest.count == 2 ? [String(rest[0])] : nil
    }
}
