import Foundation
import Synchronization
@testable import MailCore

/// Gmail over HTTP, in memory: threads with labels and a `historyId`, served as real JSON so the
/// whole `LiveGmailClient → cache → quota` stack runs. Supports list (simple query matching),
/// metadata and full thread reads, profile, `labels/INBOX`, thread modify/trash/untrash and
/// `messages/batchModify`. Every write bumps the thread's `historyId`.
final class FakeGmailServer: HTTPTransport, Sendable {
    struct Thread: Sendable {
        var id: String
        var labels: Set<String>
        var historyID: UInt64
        var messageCount = 1
        var messageIDs: [String] { (0..<messageCount).map { "\(id)-m\($0)" } }
    }

    private struct State {
        var me = "matti@example.fi"
        var threads: [String: Thread] = [:]
        /// Newest first, like Gmail's list order.
        var order: [String] = []
        var nextHistory: UInt64 = 1_000
        var calls: [String] = []
        /// "METHOD path-prefix" → reply that replaces the normal answer.
        var overrides: [String: (Int, Data)] = [:]
    }

    private let state = Mutex(State())

    var me: String { state.withLock { $0.me } }
    var calls: [String] { state.withLock { $0.calls } }
    func resetCalls() { state.withLock { $0.calls = [] } }

    /// Thread `GET`s (rows and opened threads) in the call log.
    var threadGets: [String] { calls.filter { $0.hasPrefix("GET threads/") } }

    func thread(_ id: String) -> Thread? { state.withLock { $0.threads[id] } }

    /// Adds threads at the bottom (older than everything present).
    func add(_ ids: [String], labels: Set<String> = [GmailLabel.inbox]) {
        state.withLock { s in
            for id in ids {
                s.nextHistory += 1
                s.threads[id] = Thread(id: id, labels: labels, historyID: s.nextHistory)
                s.order.append(id)
            }
        }
    }

    /// A new message arrives in `id`: it moves to the top and its `historyId` changes.
    func reply(to id: String) {
        state.withLock { s in
            guard var t = s.threads[id] else { return }
            s.nextHistory += 1
            t.historyID = s.nextHistory
            t.messageCount += 1
            t.labels.formUnion([GmailLabel.inbox, GmailLabel.unread])
            s.threads[id] = t
            s.order.removeAll { $0 == id }
            s.order.insert(id, at: 0)
        }
    }

    /// Requests whose "METHOD path" starts with `prefix` get this status and body instead.
    func override(_ prefix: String, status: Int, body: Data) {
        state.withLock { $0.overrides[prefix] = (status, body) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let full = url.path()
        let path = full.components(separatedBy: "/users/me/").last ?? full
        let line = "\(method) \(path)"
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let override = state.withLock { s -> (Int, Data)? in
            s.calls.append(line)
            return s.overrides.first { line.hasPrefix($0.key) }?.value
        }
        if let (status, body) = override { return respond(url, status, body) }

        let parts = path.split(separator: "/").map(String.init)
        switch (method, parts.first ?? "", parts.count) {
        case ("GET", "profile", 1):
            return respond(url, 200, json(["emailAddress": me]))
        case ("GET", "labels", 2):
            let unread = state.withLock { s in s.threads.values.filter { $0.labels.isSuperset(of: [GmailLabel.inbox, GmailLabel.unread]) }.count }
            return respond(url, 200, json(["id": parts[1], "threadsUnread": unread]))
        case ("GET", "threads", 1):
            return respond(url, 200, list(query: item("q") ?? "", token: item("pageToken"), max: Int(item("maxResults") ?? "") ?? 100))
        case ("GET", "threads", 2):
            guard let body = threadBody(parts[1], format: item("format") ?? "full") else { return respond(url, 404, Data("{}".utf8)) }
            return respond(url, 200, body)
        case ("POST", "threads", 3):
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let found = state.withLock { s -> Bool in
                guard var t = s.threads[parts[1]] else { return false }
                switch parts[2] {
                case "modify":
                    t.labels.formUnion(body["addLabelIds"] as? [String] ?? [])
                    t.labels.subtract(body["removeLabelIds"] as? [String] ?? [])
                case "trash":
                    t.labels.remove(GmailLabel.inbox)
                    t.labels.insert(GmailLabel.trash)
                case "untrash":
                    t.labels.remove(GmailLabel.trash)
                    t.labels.insert(GmailLabel.inbox)
                default:
                    return false
                }
                s.nextHistory += 1
                t.historyID = s.nextHistory
                s.threads[t.id] = t
                return true
            }
            return respond(url, found ? 200 : 404, Data("{}".utf8))
        case ("POST", "messages", 2) where parts[1] == "batchModify":
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let ids = Set(body["ids"] as? [String] ?? [])
            guard !ids.isEmpty, ids.count <= 1_000 else { return respond(url, 400, Data("{}".utf8)) }
            state.withLock { s in
                for (id, var t) in s.threads where !ids.isDisjoint(with: t.messageIDs) {
                    t.labels.formUnion(body["addLabelIds"] as? [String] ?? [])
                    t.labels.subtract(body["removeLabelIds"] as? [String] ?? [])
                    s.nextHistory += 1
                    t.historyID = s.nextHistory
                    s.threads[id] = t
                }
            }
            return respond(url, 204, Data())
        default:
            return respond(url, 404, Data("{}".utf8))
        }
    }

    private func respond(_ url: URL, _ status: Int, _ body: Data) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    /// Understands `in:inbox`, `is:unread` and `is:starred`; a `category:` term matches nothing.
    private func matches(_ t: Thread, _ query: String) -> Bool {
        for term in query.split(separator: " ") {
            switch term {
            case "in:inbox": if !t.labels.contains(GmailLabel.inbox) { return false }
            case "is:unread": if !t.labels.contains(GmailLabel.unread) { return false }
            case "is:starred": if !t.labels.contains(GmailLabel.starred) { return false }
            default: if term.hasPrefix("category:") { return false }
            }
        }
        return true
    }

    private func list(query: String, token: String?, max: Int) -> Data {
        let all = state.withLock { s in s.order.compactMap { s.threads[$0] }.filter { matches($0, query) } }
        let offset = token.flatMap(Int.init) ?? 0
        let page = Array(all.dropFirst(offset).prefix(max))
        var out: [String: Any] = [
            "threads": page.map { ["id": $0.id, "historyId": String($0.historyID), "snippet": "…"] },
            "resultSizeEstimate": all.count,
        ]
        if page.isEmpty { out["threads"] = nil }
        if offset + page.count < all.count { out["nextPageToken"] = String(offset + page.count) }
        return json(out)
    }

    private func threadBody(_ id: String, format: String) -> Data? {
        guard let t = thread(id) else { return nil }
        let messages: [[String: Any]] = t.messageIDs.enumerated().map { i, mid in
            var payload: [String: Any] = [
                "mimeType": "text/plain",
                "headers": [
                    ["name": "From", "value": "Lähettäjä \(id) <\(id)@example.fi>"],
                    ["name": "Subject", "value": "Aihe \(id)"],
                ],
            ]
            if format == "full" { payload["body"] = ["data": Base64URL.encode(Data("Viesti \(id)".utf8))] }
            return [
                "id": mid, "threadId": id, "labelIds": Array(t.labels).sorted(), "snippet": "…",
                "internalDate": String(1_700_000_000_000 + i * 60_000), "payload": payload,
            ]
        }
        return json(["id": id, "historyId": String(t.historyID), "messages": messages])
    }
}

/// Applies Gmail's per-method costs over a rolling 60 s window shared with other clients and
/// answers like Gmail did in the incident (403 rateLimitExceeded) once the window is full.
final class QuotaSimulatingTransport: HTTPTransport, Sendable {
    private struct State {
        var charges: [(at: Duration, units: Int)] = []
        var peak = 0
        var rejected = 0
        var rejectAll = false
    }

    let base: any HTTPTransport
    let clock: any QuotaClock
    let limit: Int
    private let state = Mutex(State())
    private let incident: Data

    init(base: any HTTPTransport, clock: any QuotaClock, limit: Int = GmailQuotaPolicy.macApp.perUserLimit) throws {
        self.base = base
        self.clock = clock
        self.limit = limit
        self.incident = try Fixture.data("gmail_403_rate_limit")
    }

    /// The highest number of units Gmail saw in any 60 s window.
    var peakWindow: Int { state.withLock { $0.peak } }
    var rejected: Int { state.withLock { $0.rejected } }
    func windowUnits() -> Int {
        let now = clock.now
        return state.withLock { s in s.charges.filter { $0.at + .seconds(60) > now }.reduce(0) { $0 + $1.units } }
    }

    /// Another client of the same account spends `units` now.
    func prefill(_ units: Int) {
        let now = clock.now
        state.withLock { $0.charges.append((now, units)) }
    }

    /// Every metered request is answered with the rate-limit 403.
    func setRejectAll(_ on: Bool) { state.withLock { $0.rejectAll = on } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint = GmailEndpoint(request) else { return try await base.send(request) }
        let now = clock.now
        let admitted = state.withLock { s -> Bool in
            s.charges.removeAll { $0.at + .seconds(60) <= now }
            let used = s.charges.reduce(0) { $0 + $1.units }
            guard !s.rejectAll, used + endpoint.units <= limit else {
                s.rejected += 1
                return false
            }
            s.charges.append((now, endpoint.units))
            s.peak = max(s.peak, used + endpoint.units)
            return true
        }
        guard admitted else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (incident, response)
        }
        return try await base.send(request)
    }
}
