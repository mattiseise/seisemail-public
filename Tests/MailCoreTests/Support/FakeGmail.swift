import Foundation
import Synchronization
@testable import MailCore

/// In-memory Gmail: queries map to ordered thread ids; operations are recorded as strings.
final class FakeGmail: GmailAPI {
    struct State {
        var me = "maija.meikalainen@gmail.com"
        var lists: [String: [String]] = [:]
        var threads: [String: MailThread] = [:]
        var calls: [String] = []
        var failing: Set<String> = []          // operation names: "modify", "trash", "untrash", "list", "thread", "send"
        var offline = false
        var threadDelays: [String: Duration] = [:]
        var summaryDelay: Duration?
        var failingThreads: Set<String> = []
        var inboxUnread = 0
        var estimates: [String: Int] = [:]
        var sent: [(Data, String?)] = []
        var attachments: [String: Data] = [:]
        var sendAs: [SendAsSignature] = []
        /// Thrown by every `listThreads` call (after it is recorded) while set.
        var listError: GmailError?
        /// While set and closed, every `listThreads` call waits here after it is recorded.
        var listGate: CallGate?
        var listMaxResults: [Int] = []
        var listsInFlight = 0
        var maxListsInFlight = 0
        /// Rows carry their message ids, so bulk actions can use batchModify.
        var summaryMessageIDs = false
        /// While set and closed, every modify, batchModify and trash waits here after it is
        /// recorded, so a test can wait for `mutatingCalls` and act while those writes are in flight.
        var writeGate: CallGate?
        /// While set and closed, every `threadSummary` waits here with the server state it read on arrival.
        var summaryGate: CallGate?
        /// While set and closed, `thread(id:)` for that id waits here after it is recorded.
        var threadGates: [String: CallGate] = [:]
    }

    private func passWriteGate() async throws {
        try await state.withLock { $0.writeGate }?.pass()
    }

    /// Closes a new gate in front of every later write and returns it; `open()` it to let them through.
    func holdWrites() -> CallGate {
        let gate = CallGate()
        update { $0.writeGate = gate }
        return gate
    }

    /// Closes a new gate in front of every later `threadSummary` response and returns it.
    func holdSummaries() -> CallGate {
        let gate = CallGate()
        update { $0.summaryGate = gate }
        return gate
    }

    /// Closes a new gate in front of `thread(id:)` for `id` and returns it.
    func holdThread(_ id: String) -> CallGate {
        let gate = CallGate()
        update { $0.threadGates[id] = gate }
        return gate
    }

    /// Closes a new gate in front of every later `listThreads` call and returns it.
    func holdLists() -> CallGate {
        let gate = CallGate()
        update { $0.listGate = gate }
        return gate
    }

    let state = Mutex(State())

    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }
    var mutatingCalls: [String] { calls.filter { !$0.hasPrefix("list") && !$0.hasPrefix("summary") && !$0.hasPrefix("thread ") && !$0.hasPrefix("count") && $0 != "profile" } }

    @discardableResult
    func addThread(_ id: String, labels: Set<String> = [GmailLabel.inbox], subject: String? = nil, in queries: [String] = ["in:inbox"]) -> MailThread {
        let message = Message(
            id: "\(id)-m", threadID: id, from: MailAddress(name: "Lähettäjä \(id)", email: "\(id)@example.fi"),
            replyTo: [], to: [MailAddress(name: nil, email: "maija.meikalainen@gmail.com")], cc: [],
            date: Date(timeIntervalSince1970: 1_700_000_000), subject: subject ?? "Aihe \(id)", snippet: "…",
            textBody: "Viesti \(id)", htmlBody: nil, attachments: [], labelIDs: labels,
            messageIDHeader: "<\(id)@example.fi>", references: nil
        )
        let thread = MailThread(id: id, messages: [message])
        update { s in
            s.threads[id] = thread
            for q in queries { s.lists[q, default: []].append(id) }
        }
        return thread
    }

    private func record(_ call: String, op: String) throws {
        try state.withLock { s in
            s.calls.append(call)
            if s.offline { throw GmailError.offline }
            if s.failing.contains(op) { throw GmailError.http(500, "fail") }
        }
    }

    func profileEmail() async throws -> String {
        try record("profile", op: "profile")
        return state.withLock { $0.me }
    }

    func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try record("list \(query) \(pageToken ?? "-")", op: "list")
        let (error, gate) = state.withLock { s in
            s.listMaxResults.append(maxResults)
            s.listsInFlight += 1
            s.maxListsInFlight = max(s.maxListsInFlight, s.listsInFlight)
            return (s.listError, s.listGate)
        }
        defer { update { $0.listsInFlight -= 1 } }
        try await gate?.pass()
        if let error { throw error }
        let all = state.withLock { $0.lists[query] ?? [] }
        let offset = pageToken.flatMap(Int.init) ?? 0
        let slice = Array(all.dropFirst(offset).prefix(maxResults))
        let next = offset + slice.count < all.count ? String(offset + slice.count) : nil
        return ThreadPage(ids: slice, nextPageToken: next, estimate: all.count)
    }

    func threadSummary(id: String, me: String?) async throws -> ThreadSummary {
        // Snapshot server state when the request arrives; a delayed response carries that older state.
        try record("summary \(id)", op: "summary")
        let snapshot = state.withLock { $0.threads[id] }
        if let delay = state.withLock({ $0.summaryDelay }) { try await Task.sleep(for: delay) }
        try await state.withLock { $0.summaryGate }?.pass()
        guard let t = snapshot else { throw GmailError.http(404, id) }
        let m = t.messages.last!
        let withIDs = state.withLock { $0.summaryMessageIDs }
        return ThreadSummary(id: id, subject: t.subject, sender: m.from?.displayName ?? "", snippet: m.snippet,
                             date: m.date, labelIDs: t.labelIDs, hasAttachments: false, messageCount: t.messages.count,
                             messageIDs: withIDs ? t.messages.map(\.id) : [])
    }

    func thread(id: String) async throws -> MailThread {
        let delay = state.withLock { $0.threadDelays[id] }
        if let delay { try await Task.sleep(for: delay) }
        try record("thread \(id)", op: "thread")
        try await state.withLock { $0.threadGates[id] }?.pass()
        guard let t = state.withLock({ $0.threads[id] }) else { throw GmailError.http(404, id) }
        return t
    }

    func modify(threadID: String, add: [String], remove: [String]) async throws {
        try record("modify \(threadID) +\(add.joined(separator: ",")) -\(remove.joined(separator: ","))", op: "modify")
        try await passWriteGate()
        if state.withLock({ $0.failingThreads.contains(threadID) }) { throw GmailError.http(500, "fail") }
        update { s in
            guard var t = s.threads[threadID] else { return }
            for i in t.messages.indices {
                t.messages[i].labelIDs.formUnion(add)
                t.messages[i].labelIDs.subtract(remove)
            }
            s.threads[threadID] = t
        }
    }

    func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {
        try record("batchModify \(messageIDs.joined(separator: ",")) +\(add.joined(separator: ",")) -\(remove.joined(separator: ","))", op: "batchModify")
        try await passWriteGate()
        let ids = Set(messageIDs)
        if state.withLock({ s in s.threads.values.contains { t in s.failingThreads.contains(t.id) && t.messages.contains { ids.contains($0.id) } } }) {
            throw GmailError.http(500, "fail")
        }
        update { s in
            for (key, var t) in s.threads {
                var touched = false
                for i in t.messages.indices where ids.contains(t.messages[i].id) {
                    t.messages[i].labelIDs.formUnion(add)
                    t.messages[i].labelIDs.subtract(remove)
                    touched = true
                }
                if touched { s.threads[key] = t }
            }
        }
    }

    func trash(threadID: String) async throws {
        try record("trash \(threadID)", op: "trash")
        try await passWriteGate()
        if state.withLock({ $0.failingThreads.contains(threadID) }) { throw GmailError.http(500, "fail") }
    }
    func untrash(threadID: String) async throws { try record("untrash \(threadID)", op: "untrash") }

    func send(raw: Data, threadID: String?) async throws {
        try record("send \(threadID ?? "-")", op: "send")
        update { $0.sent.append((raw, threadID)) }
    }

    func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try record("attachment \(messageID)/\(attachmentID)", op: "attachment")
        return state.withLock { $0.attachments[attachmentID] } ?? Data()
    }

    func inboxUnreadCount() async throws -> Int {
        try record("count inbox", op: "count")
        return state.withLock { $0.inboxUnread }
    }

    func unreadEstimate(query: String) async throws -> Int {
        try record("count \(query)", op: "count")
        return state.withLock { $0.estimates[query] ?? 0 }
    }

    func sendAsSignatures() async throws -> [SendAsSignature] {
        try record("sendAs", op: "sendAs")
        return state.withLock { $0.sendAs }
    }
}
