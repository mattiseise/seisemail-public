import Foundation
import Synchronization
@testable import MailCore

/// `FakeGmail` plus the label endpoints. Wraps the upstream fake (unchanged) and records into its `calls`,
/// so `mutatingCalls` keeps working: reads start with "list" or "thread ", writes with "label " or "modify".
final class LabelFakeGmail: GmailLabelsAPI {
    /// Runs before the call it is attached to, outside any lock. `call` counts from 1.
    typealias Hook = @Sendable (_ fake: LabelFakeGmail, _ threadID: String, _ call: Int) -> Void

    struct LabelState {
        var labels: [GmailLabelInfo] = LabelFakeGmail.systemLabels
        var visibility: [String: LabelVisibility] = [:]     // by id
        var nextNumber = 1                                  // "Label_1", "Label_2", … in creation order
        var createErrors: [String: Int] = [:]               // lowercased name → status (400 = reserved)
        var deleteErrors: [String: Int] = [:]               // id → status
        var strictLabelIDs = true                           // modify with an unregistered add/remove ID → 400
        var unknownLabelStatus = 400                        // the status for that; Gmail's is undocumented (400 or 404)
        var urlSessionCancellation = false                  // a call in a cancelled task throws URLError(.cancelled)
        var threadLabelsError: (any Error)?                 // every threadLabels throws it (after recording)
        var forcedModifyStatus: Int?                        // every modify → .http(status, "forced")
        var threadLabelsDelay: Duration?
        var threadLabelsGate: Gate?                         // every threadLabels waits here (after recording)
        var staleCache: [String: Set<String>] = [:]         // thread id → labels a cached read still returns
        var listLabelsDelay: Duration?                      // response carries the state at request time
        var listLabelsGate: Gate?                           // the same, held until the test opens it
        var summaryGate: Gate?                              // every threadSummary waits here (after recording)
        var beforeModify: Hook?
        var beforeThreadLabels: Hook?
        var modifyCalls = 0
        var threadLabelsCalls = 0
    }

    /// System labels: id == name.
    static let systemLabels: [GmailLabelInfo] = [
        "INBOX", "UNREAD", "STARRED", "IMPORTANT", "TRASH", "SPAM", "SENT", "DRAFT", "CHAT",
        "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ].map { GmailLabelInfo(id: $0, name: $0, kind: .system) }

    let base: FakeGmail
    let labelState = Mutex(LabelState())

    init(base: FakeGmail = FakeGmail()) {
        self.base = base
    }

    var calls: [String] { base.calls }
    var mutatingCalls: [String] { base.mutatingCalls }
    func update(_ body: (inout FakeGmail.State) -> Void) { base.update(body) }
    func updateLabels(_ body: (inout LabelState) -> Void) { labelState.withLock { body(&$0) } }

    /// Same semantics as `FakeGmail.record`: append, then fail if offline or the op is in `failing`.
    /// With `urlSessionCancellation`, a cancelled task gets URLError(.cancelled), as URLSessionTransport gives.
    private func record(_ call: String, op: String) throws {
        let urlCancelled = labelState.withLock { $0.urlSessionCancellation } && Task.isCancelled
        try base.state.withLock { s in
            s.calls.append(call)
            if urlCancelled { throw URLError(.cancelled) }
            if s.offline { throw GmailError.offline }
            if s.failing.contains(op) { throw GmailError.http(500, "fail") }
        }
    }

    // MARK: - Server-side helpers (no call recorded)

    /// Gmail label names are unique case-insensitively, so a case-insensitive duplicate is a test bug.
    @discardableResult
    func addLabel(_ name: String, visibility: LabelVisibility = .shown) -> String {
        labelState.withLock { s in
            precondition(!s.labels.contains { $0.name.lowercased() == name.lowercased() }, "duplicate label \(name)")
            let id = "Label_\(s.nextNumber)"
            s.nextNumber += 1
            s.labels.append(GmailLabelInfo(id: id, name: name, kind: .user))
            s.visibility[id] = visibility
            return id
        }
    }

    /// Matti renames a label in Gmail: the ID stays, the name changes.
    func renameLabel(_ id: String, to name: String) {
        labelState.withLock { s in
            guard let i = s.labels.firstIndex(where: { $0.id == id }) else { return }
            s.labels[i] = GmailLabelInfo(id: id, name: name, kind: s.labels[i].kind)
        }
    }

    func labelID(_ name: String) -> String? {
        labelState.withLock { s in s.labels.first(where: { $0.name == name })?.id }
    }

    /// Adds to every message of the thread.
    func apply(_ labelIDs: Set<String>, to threadID: String) {
        base.update { s in
            guard var t = s.threads[threadID] else { return }
            for i in t.messages.indices { t.messages[i].labelIDs.formUnion(labelIDs) }
            s.threads[threadID] = t
        }
    }

    func strip(_ labelIDs: Set<String>, from threadID: String) {
        base.update { s in
            guard var t = s.threads[threadID] else { return }
            for i in t.messages.indices { t.messages[i].labelIDs.subtract(labelIDs) }
            s.threads[threadID] = t
        }
    }

    /// A reply arriving: a new last message "\(threadID)-m\(n)" carrying only `labels`.
    func addMessage(to threadID: String, labels: Set<String>) {
        base.update { s in
            guard var t = s.threads[threadID], var m = t.messages.last else { return }
            m.id = "\(threadID)-m\(t.messages.count + 1)"
            m.labelIDs = labels
            t.messages.append(m)
            s.threads[threadID] = t
        }
    }

    /// Another device deleting a label: gone from the registry and from every message. No-op if absent.
    func deleteLabelServerSide(_ name: String) {
        let id: String? = labelState.withLock { s in
            guard let i = s.labels.firstIndex(where: { $0.name == name }) else { return nil }
            let id = s.labels[i].id
            s.labels.remove(at: i)
            s.visibility[id] = nil
            return id
        }
        if let id { stripEverywhere(id) }
    }

    /// Union over messages, IDs mapped to names (system IDs are their own names; unknown IDs stay as IDs).
    func labelNames(of threadID: String) -> Set<String> {
        let ids = base.state.withLock { $0.threads[threadID]?.labelIDs ?? [] }
        let names = labelState.withLock { s in Dictionary(s.labels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
        return Set(ids.map { names[$0] ?? $0 })
    }

    func visibility(ofLabelNamed name: String) -> LabelVisibility? {
        labelState.withLock { s in
            guard let label = s.labels.first(where: { $0.name == name }) else { return nil }
            return s.visibility[label.id]
        }
    }

    /// Ensures "Torkku" (if missing), then "Torkku/<wake>" (hidden, if `wake` is given), then adds the thread.
    @discardableResult
    func addSnoozedThread(_ id: String, wake: String?, extra: Set<String> = [], in queries: [String] = []) -> MailThread {
        var labels = extra
        labels.insert(labelID("Torkku") ?? addLabel("Torkku"))
        if let wake {
            let name = "Torkku/\(wake)"
            labels.insert(labelID(name) ?? addLabel(name, visibility: .hidden))
        }
        return base.addThread(id, labels: labels, in: queries)
    }

    private func stripEverywhere(_ labelID: String) {
        base.update { s in
            for id in Array(s.threads.keys) {
                guard var t = s.threads[id] else { continue }
                for i in t.messages.indices { t.messages[i].labelIDs.remove(labelID) }
                s.threads[id] = t
            }
        }
    }

    // MARK: - GmailAPI (delegated; modify intercepted)

    func profileEmail() async throws -> String { try await base.profileEmail() }

    func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await base.listThreads(query: query, pageToken: pageToken, maxResults: maxResults)
    }

    /// With `summaryGate`: the call is made (recorded, server state read) at once, and its result or error is held.
    func threadSummary(id: String, me: String?) async throws -> ThreadSummary {
        let gate = labelState.withLock { $0.summaryGate }
        let result: Result<ThreadSummary, any Error>
        do { result = .success(try await base.threadSummary(id: id, me: me)) } catch { result = .failure(error) }
        if let gate { await gate.wait() }
        return try result.get()
    }

    func thread(id: String) async throws -> MailThread { try await base.thread(id: id) }

    func modify(threadID: String, add: [String], remove: [String]) async throws {
        let (hook, call) = labelState.withLock { s in
            s.modifyCalls += 1
            return (s.beforeModify, s.modifyCalls)
        }
        hook?(self, threadID, call)
        let (unknown, unknownStatus, forced) = labelState.withLock { s in
            let known = Set(s.labels.map(\.id))
            let unknown = s.strictLabelIDs ? (add + remove).first(where: { !known.contains($0) }) : nil
            return (unknown, s.unknownLabelStatus, s.forcedModifyStatus)
        }
        let exists = base.state.withLock { $0.threads[threadID] != nil }
        let description = "modify \(threadID) +\(add.joined(separator: ",")) -\(remove.joined(separator: ","))"
        if let unknown {
            try record(description, op: "modify")
            throw GmailError.http(unknownStatus, "Invalid label: \(unknown)")
        }
        if let forced {
            try record(description, op: "modify")
            throw GmailError.http(forced, "forced")
        }
        if !exists {                                            // Gmail: 404 for an unknown thread
            try record(description, op: "modify")
            throw GmailError.http(404, threadID)
        }
        try await base.modify(threadID: threadID, add: add, remove: remove)
    }

    func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {
        try await base.batchModify(messageIDs: messageIDs, add: add, remove: remove)
    }

    func trash(threadID: String) async throws { try await base.trash(threadID: threadID) }

    func untrash(threadID: String) async throws { try await base.untrash(threadID: threadID) }

    func send(raw: Data, threadID: String?) async throws { try await base.send(raw: raw, threadID: threadID) }

    func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try await base.attachmentData(messageID: messageID, attachmentID: attachmentID)
    }

    func inboxUnreadCount() async throws -> Int { try await base.inboxUnreadCount() }

    func unreadEstimate(query: String) async throws -> Int { try await base.unreadEstimate(query: query) }

    func sendAsSignatures() async throws -> [SendAsSignature] { try await base.sendAsSignatures() }

    // MARK: - GmailLabelsAPI

    func listLabels() async throws -> [GmailLabelInfo] {
        try record("list labels", op: "labels")
        let (labels, delay, gate) = labelState.withLock { ($0.labels, $0.listLabelsDelay, $0.listLabelsGate) }
        if let delay { try await Task.sleep(for: delay) }
        if let gate { await gate.wait() }
        return labels
    }

    func createLabel(name: String, visibility: LabelVisibility) async throws -> GmailLabelInfo {
        try record("label create \(name)", op: "createLabel")
        return try labelState.withLock { s in
            if let status = s.createErrors[name.lowercased()] { throw GmailError.http(status, "Invalid label name") }
            if s.labels.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                throw GmailError.http(409, "Label name exists or conflicts")
            }
            let info = GmailLabelInfo(id: "Label_\(s.nextNumber)", name: name, kind: .user)
            s.nextNumber += 1
            s.labels.append(info)
            s.visibility[info.id] = visibility
            return info
        }
    }

    func deleteLabel(id: String) async throws {
        try record("label delete \(id)", op: "deleteLabel")
        try labelState.withLock { s in
            if let status = s.deleteErrors[id] { throw GmailError.http(status, "delete failed") }
            guard let i = s.labels.firstIndex(where: { $0.id == id }) else { throw GmailError.http(404, id) }
            s.labels.remove(at: i)
            s.visibility[id] = nil
        }
        stripEverywhere(id)
    }

    /// Threads carrying the label, all and unread (Gmail's `threadsTotal` / `threadsUnread`).
    func labelCounts(id: String) async throws -> LabelCounts {
        try record("count label \(id)", op: "labelGet")
        return base.state.withLock { s in
            let carrying = s.threads.values.filter { $0.labelIDs.contains(id) }
            return LabelCounts(threadsTotal: carrying.count,
                               threadsUnread: carrying.filter { $0.labelIDs.contains(GmailLabel.unread) }.count)
        }
    }

    /// Threads whose label union contains every ID; TRASH/SPAM threads only with `includeSpamTrash`. Sorted by ID.
    func listThreadIDs(labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try record("list labelIds \(labelIDs.joined(separator: ",")) \(includeSpamTrash ? "spamTrash" : "-") \(pageToken ?? "-")", op: "listIDs")
        let wanted = Set(labelIDs)
        let all = base.state.withLock { s in
            s.threads.values.filter { t in
                let labels = t.labelIDs
                guard labels.isSuperset(of: wanted) else { return false }
                return includeSpamTrash || (!labels.contains("TRASH") && !labels.contains("SPAM"))
            }.map(\.id).sorted()
        }
        let offset = pageToken.flatMap(Int.init) ?? 0
        let slice = Array(all.dropFirst(offset).prefix(maxResults))
        let next = offset + slice.count < all.count ? String(offset + slice.count) : nil
        return ThreadPage(ids: slice, nextPageToken: next, estimate: all.count)
    }

    /// A fresh read records "thread labels <id>", a cached one "thread labels cached <id>". A cached read
    /// returns the server's labels unless `staleCache` holds older ones for the thread.
    func threadLabels(id: String, fresh: Bool) async throws -> ThreadLabels {
        let (hook, call, delay, gate) = labelState.withLock { s in
            s.threadLabelsCalls += 1
            return (s.beforeThreadLabels, s.threadLabelsCalls, s.threadLabelsDelay, s.threadLabelsGate)
        }
        hook?(self, id, call)
        try record(fresh ? "thread labels \(id)" : "thread labels cached \(id)", op: "threadLabels")
        if let error = labelState.withLock({ $0.threadLabelsError }) { throw error }
        if let delay { try await Task.sleep(for: delay) }
        if let gate { await gate.wait() }
        if !fresh, let stale = labelState.withLock({ $0.staleCache[id] }) {
            return ThreadLabels(threadID: id, messageLabelIDs: [stale], historyID: nil)
        }
        guard let t = base.state.withLock({ $0.threads[id] }) else { throw GmailError.http(404, id) }
        return ThreadLabels(threadID: id, messageLabelIDs: t.messages.map(\.labelIDs), historyID: nil)
    }
}
