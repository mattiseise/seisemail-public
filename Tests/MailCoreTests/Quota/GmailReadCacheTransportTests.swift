import Foundation
import Synchronization
import Testing
@testable import MailCore

/// A tiny Gmail for cache tests: threads with a `historyId`, scripted per-request status.
final class CacheTestServer: Sendable {
    private struct State {
        var history: [String: UInt64] = [:]
        var order: [String] = []
        var withHistoryInBody = true
        var listOverride: [String: UInt64]?
        var getStatus = 200
        var writeStatus = 200
        var writeThrows = false
        var getGate: CheckedContinuation<Void, Never>?
        var holdNextGet = false
        var heldGet = false
    }

    private let state = Mutex(State())

    func set(_ id: String, history: UInt64) {
        state.withLock { s in
            if s.history[id] == nil { s.order.append(id) }
            s.history[id] = history
        }
    }

    func configure(_ body: @Sendable (inout Bool, inout Int, inout Int, inout Bool) -> Void) {
        state.withLock { body(&$0.withHistoryInBody, &$0.getStatus, &$0.writeStatus, &$0.writeThrows) }
    }

    /// The next list reports these ids and historyIds instead of the current ones (a late response).
    func overrideNextList(_ list: [String: UInt64]) { state.withLock { $0.listOverride = list } }

    func holdNextGet() { state.withLock { $0.holdNextGet = true } }
    var isHoldingGet: Bool { state.withLock { $0.heldGet } }
    func releaseGet() {
        let c = state.withLock { s -> CheckedContinuation<Void, Never>? in
            defer { s.getGate = nil; s.heldGet = false }
            return s.getGate
        }
        c?.resume()
    }

    func reply(_ r: URLRequest) async throws -> HeaderStubTransport.Reply {
        let path = r.url!.path().replacingOccurrences(of: "/gmail/v1/users/me/", with: "")
        let parts = path.split(separator: "/").map(String.init)
        if r.httpMethod != "GET" {
            let (status, throwsError) = state.withLock { ($0.writeStatus, $0.writeThrows) }
            if throwsError { throw URLError(.networkConnectionLost) }
            return .init(status: status, body: Data("{}".utf8))
        }
        if parts == ["threads"] {
            let threads = state.withLock { s -> [[String: Any]] in
                if let o = s.listOverride {
                    s.listOverride = nil
                    return o.sorted { $0.key < $1.key }.map { ["id": $0.key, "historyId": String($0.value)] }
                }
                return s.order.map { ["id": $0, "historyId": String(s.history[$0]!)] }
            }
            return .init(status: 200, body: json(["threads": threads, "resultSizeEstimate": threads.count]))
        }
        let id = parts[1]
        let hold = state.withLock { s -> Bool in
            defer { s.holdNextGet = false }
            return s.holdNextGet
        }
        if hold {
            await withCheckedContinuation { c in state.withLock { $0.getGate = c; $0.heldGet = true } }
        }
        let (status, history, withHistory) = state.withLock { ($0.getStatus, $0.history[id] ?? 1, $0.withHistoryInBody) }
        guard status == 200 else { return .init(status: status, body: Data("{}".utf8)) }
        var body = try JSONSerialization.jsonObject(with: Fixture.data("thread_metadata_history")) as! [String: Any]
        body["id"] = id
        body["historyId"] = withHistory ? String(history) : nil
        // Message ids per thread ("t1-m1", "t1-m2"), so batchModify bodies can name them.
        body["messages"] = (body["messages"] as! [[String: Any]]).map { m in
            var m = m
            m["id"] = "\(id)-\(m["id"] as! String)"
            m["threadId"] = id
            return m
        }
        return .init(status: 200, body: try JSONSerialization.data(withJSONObject: body))
    }
}

@Suite struct GmailReadCacheTransportTests {
    let clock = ManualQuotaClock()
    let server = CacheTestServer()
    let stub: HeaderStubTransport
    let cache: GmailReadCacheTransport
    let api: LiveGmailClient

    init() {
        let server = self.server
        stub = HeaderStubTransport(clock: clock) { r, _ in try await server.reply(r) }
        cache = GmailReadCacheTransport(base: stub, clock: clock, policy: .init(capacity: 3))
        api = LiveGmailClient(auth: FakeTokens(), transport: cache,
                              retry: RetryPolicy(delays: [], sleep: { _ in }))
    }

    func gets(_ id: String) -> Int {
        stub.log.filter { $0.request.httpMethod == "GET" && $0.request.url!.path().hasSuffix("/threads/\(id)") }.count
    }

    func list() async throws { _ = try await api.listThreads(query: "in:inbox", pageToken: nil, maxResults: 50) }
    func row(_ id: String) async throws -> ThreadSummary { try await api.threadSummary(id: id, me: nil) }

    func request(_ method: String, _ path: String, policy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!, cachePolicy: policy)
        r.httpMethod = method
        return r
    }

    @Test func unchangedThreadServedFromCache() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        try await list()
        _ = try await row("t1")
        #expect(gets("t1") == 1)
        #expect(cache.stats.hits == 1)
    }

    @Test func minimalCachedOnlyWhenNotFresh() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await api.threadLabels(id: "t1", fresh: false)            // miss, stored
        _ = try await api.threadLabels(id: "t1", fresh: false)            // hit
        #expect(gets("t1") == 1)
        _ = try await api.threadLabels(id: "t1", fresh: true)             // always Gmail
        _ = try await api.threadLabels(id: "t1")                          // the default is fresh
        #expect(gets("t1") == 3)
        #expect(stub.log.last?.request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(GmailEndpoint(stub.log.last!.request)?.lane == .interactive)
    }

    @Test func changedHistoryRefetches() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        server.set("t1", history: 1002)
        try await list()
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func noObservationNoHit() async throws {
        server.set("t1", history: 1001)
        _ = try await row("t1")
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func observationOlderThan120sNoHit() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        clock.advance(by: .seconds(120))
        _ = try await row("t1")
        #expect(gets("t1") == 1)                               // exactly 120 s still counts
        clock.advance(by: .seconds(1))
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func equalListRefreshesObservation() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        clock.advance(by: .seconds(100))
        try await list()
        clock.advance(by: .seconds(100))
        _ = try await row("t1")
        #expect(gets("t1") == 1)
    }

    @Test func olderListCannotRollBackObservation() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")                                 // body 1001 cached
        server.set("t1", history: 1002)
        try await list()                                        // observation 1002
        server.overrideNextList(["t1": 1001])
        try await list()                                        // a late list still says 1001
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func reloadPolicyBypassesLookupButStores() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        let query = "format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Content-Type"
        _ = try await cache.send(request("GET", "threads/t1?\(query)", policy: .reloadIgnoringLocalCacheData))
        #expect(gets("t1") == 2)
        server.set("t1", history: 1002)
        try await list()
        _ = try await cache.send(request("GET", "threads/t1?\(query)", policy: .reloadIgnoringLocalCacheData))
        _ = try await row("t1")                                  // served from the fresh read's body
        #expect(gets("t1") == 3)
    }

    @Test func fullFormatNotCached() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await api.thread(id: "t1")
        _ = try await api.thread(id: "t1")
        #expect(gets("t1") == 2)
    }

    @Test func rawFormatNotCached() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await cache.send(request("GET", "threads/t1?format=raw"))
        _ = try await cache.send(request("GET", "threads/t1?format=raw"))
        #expect(gets("t1") == 2)
    }

    @Test func bodyWithoutHistoryIdNotCached() async throws {
        server.set("t1", history: 1001)
        server.configure { withHistory, _, _, _ in withHistory = false }
        try await list()
        _ = try await row("t1")
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test(arguments: ["success", "error", "throw"])
    func writeInvalidatesOnSuccessErrorAndThrow(_ outcome: String) async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        server.configure { _, _, writeStatus, writeThrows in
            writeStatus = outcome == "error" ? 500 : 200
            writeThrows = outcome == "throw"
        }
        _ = try? await cache.send(request("POST", "threads/t1/modify"))
        try await list()                                         // same historyId: a stale server view
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func getInFlightAcrossWriteNotStored() async throws {
        server.set("t1", history: 1001)
        try await list()
        server.holdNextGet()
        let slow = Task { try await row("t1") }
        #expect(await eventually { server.isHoldingGet })
        _ = try await cache.send(request("POST", "threads/t1/modify"))
        server.releaseGet()
        _ = try await slow.value
        try await list()
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func listInFlightAcrossWriteNotObserved() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        _ = try await cache.send(request("POST", "threads/t1/modify"))
        _ = try await row("t1")                                   // refetched, stored again…
        // …but no observation survives the write, so the next read must wait for a new list.
        _ = try await row("t1")
        #expect(gets("t1") == 3)
    }

    @Test func messageWriteClearsAll() async throws {
        server.set("t1", history: 1001)
        server.set("t2", history: 1002)
        try await list()
        _ = try await row("t1")
        _ = try await row("t2")
        _ = try await cache.send(request("POST", "messages/batchModify"))
        try await list()
        _ = try await row("t1")
        _ = try await row("t2")
        #expect(gets("t1") == 2)
        #expect(gets("t2") == 2)
    }

    func batchModify(_ ids: [String]) throws -> URLRequest {
        var r = request("POST", "messages/batchModify")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids, "addLabelIds": [], "removeLabelIds": ["UNREAD"]])
        return r
    }

    func cacheTwoRows() async throws {
        server.set("t1", history: 1001)
        server.set("t2", history: 1002)
        try await list()
        _ = try await row("t1")
        _ = try await row("t2")
    }

    @Test func batchModifyDropsOnlyTheThreadsItTouches() async throws {
        try await cacheTwoRows()
        _ = try await cache.send(try batchModify(["t1-m1", "t1-m2"]))
        try await list()
        _ = try await row("t1")
        _ = try await row("t2")
        #expect(gets("t1") == 2)
        #expect(gets("t2") == 1)
    }

    @Test func batchModifyWithAnUnknownMessageClearsAll() async throws {
        try await cacheTwoRows()
        _ = try await cache.send(try batchModify(["t1-m1", "elsewhere"]))
        try await list()
        _ = try await row("t1")
        _ = try await row("t2")
        #expect(gets("t1") == 2)
        #expect(gets("t2") == 2)
    }

    @Test func messageModifyDropsItsThreadOnly() async throws {
        try await cacheTwoRows()
        _ = try await cache.send(request("POST", "messages/t2-m1/modify"))
        try await list()
        _ = try await row("t1")
        _ = try await row("t2")
        #expect(gets("t1") == 1)
        #expect(gets("t2") == 2)
    }

    @Test func getInFlightAcrossBatchModifyNotStored() async throws {
        try await cacheTwoRows()
        server.holdNextGet()
        let slow = Task { try await api.thread(id: "t1") }       // full format: not cached; only holds the gate
        #expect(await eventually { server.isHoldingGet })
        server.releaseGet()
        _ = try await slow.value
        server.set("t1", history: 1003)
        try await list()
        server.holdNextGet()
        let stale = Task { try await row("t1") }
        #expect(await eventually { server.isHoldingGet })
        _ = try await cache.send(try batchModify(["t1-m1"]))
        server.releaseGet()
        _ = try await stale.value                                 // started before the write: not kept
        try await list()
        _ = try await row("t1")
        #expect(gets("t1") == 4)
    }

    @Test func bookkeepingForgetsThreadsAfterAnHour() throws {
        var state = GmailReadCache(policy: .init())
        func list(_ ids: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["threads": ids.map { ["id": $0, "historyId": "1001"] }])
        }
        let ids = (0..<500).map { "t\($0)" }
        state.observeList(try list(ids), startedAt: state.writeSeq, now: .seconds(100))
        state.invalidate(threadIDs: Set(ids.prefix(100)), now: .seconds(100))
        #expect(state.trackedThreads.observations == 400)
        #expect(state.trackedThreads.writes == 100)
        state.observeList(try list(["new"]), startedAt: state.writeSeq, now: .seconds(100 + 3_601))
        #expect(state.trackedThreads.observations == 1)
        #expect(state.trackedThreads.writes == 0)
    }

    @Test func labelWriteKeepsRows() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        _ = try await cache.send(request("POST", "labels"))
        _ = try await row("t1")
        #expect(gets("t1") == 1)
    }

    @Test func lruEvicts() async throws {
        for (i, id) in ["t1", "t2", "t3", "t4"].enumerated() { server.set(id, history: UInt64(1001 + i)) }
        try await list()
        for id in ["t1", "t2", "t3"] { _ = try await row(id) }
        _ = try await row("t1")                                   // t1 is now the most recent
        _ = try await row("t4")                                   // capacity 3: evicts t2
        _ = try await row("t1")
        _ = try await row("t2")
        #expect(gets("t1") == 1)
        #expect(gets("t2") == 2)
    }

    @Test func maxAgeForcesRefetch() async throws {
        server.set("t1", history: 1001)
        try await list()
        _ = try await row("t1")
        clock.advance(by: .seconds(3_601))
        try await list()
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func non2xxNotStored() async throws {
        server.set("t1", history: 1001)
        try await list()
        server.configure { _, getStatus, _, _ in getStatus = 404 }
        _ = try? await row("t1")
        server.configure { _, getStatus, _, _ in getStatus = 200 }
        _ = try await row("t1")
        _ = try await row("t1")
        #expect(gets("t1") == 2)
    }

    @Test func hitDecodesToSameSummary() async throws {
        server.set("t1", history: 1001)
        try await list()
        let miss = try await row("t1")
        try await list()
        let hit = try await row("t1")
        #expect(gets("t1") == 1)
        #expect(hit == miss)
    }

    @Test func factoryOrder() throws {
        let live = try #require(GmailTransports.live() as? GmailReadCacheTransport)
        #expect(live.base is GmailQuotaTransport)
        let daemon = try #require(GmailTransports.live(policy: .daemon) as? GmailReadCacheTransport)
        #expect((daemon.base as? GmailQuotaTransport)?.policy == .daemon)
    }
}
