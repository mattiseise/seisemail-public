import Foundation
import Synchronization
@testable import MailCore

/// `LabelFakeGmail` plus the daemon's sync endpoints (design phase2-daemon §4 `GmailSyncAPI`, §17 "Fakes").
///
/// - Messages carry headers (lowercased name → values) and an `internalDate` next to the labels the base fake keeps.
/// - Every delivered or inserted message becomes one `messagesAdded` history record; every write bumps the
///   mailbox `historyId`, as Gmail's does. History pages over records; the page token is the last record id of
///   the previous page, so a caller that pages with either the original start or its new checkpoint gets the
///   same records.
/// - `expiredBelow` answers `history.list` below that id with `GmailSyncError.historyExpired` (Gmail's 404);
///   `lagAfter` hides newer records while `historyId` already reports them (history lag).
/// - Searches (`threads.list`, `messages.list`) understand `in:inbox`, `in:sent`, `after:<epoch>`,
///   `newer_than:<n>d`, `label:` and `-label:` with Gmail's search names (lowercased, `/` and space → `-`).
///   Any other term matches nothing, so an unexpected query shows up as missing work.
///
/// Calls are recorded in the base fake's `calls`: reads start with "list", "thread ", "message headers" or
/// "profile"; writes are "modify", "label create", "label delete", "insert", "batchModify", "trash", "untrash" and
/// "send". `writes` filters them. `timedCalls` stamps each call with `now()`, for per-minute unit checks.
final class SyncFakeGmail: GmailSyncAPI {
    struct Meta: Sendable {
        var headers: [String: [String]]
        var internalDate: Date
    }

    struct Record: Sendable {
        var id: UInt64
        var added: [AddedMessage]
    }

    struct SyncState {
        var historyID: UInt64 = 1_000
        var records: [Record] = []
        /// `history.list` with a start below this id → `GmailSyncError.historyExpired`.
        var expiredBelow: UInt64?
        /// Records with a higher id are not listed yet; `historyId` is reported as usual.
        var lagAfter: UInt64?
        /// Gmail may return fewer items than `maxResults`; these cap the page sizes.
        var historyPageSize: Int?
        var messagePageSize: Int?
        var threadPageSize: Int?
        var meta: [String: Meta] = [:]
        /// thread id → errors thrown by its next `threadHeaders` calls, one each (after the call is recorded).
        var threadHeaderErrors: [String: [any Error]] = [:]
        /// thread id → error thrown by every `threadHeaders` call.
        var failingThreadHeaders: [String: any Error] = [:]
        /// Thrown by the next `history` calls, one each (after the call is recorded).
        var historyErrors: [any Error] = []
        /// page token ("-" for the first page) → error thrown once by `listMessageIDs` (after the call is recorded).
        var messageListErrors: [String: any Error] = [:]
        /// While set, every call throws it before anything is recorded (an expired or failing token endpoint).
        var failAll: (any Error)?
        /// Every API call, also the ones `failAll` refused.
        var attempts = 0
        var nextNote = 1
        var inserted: [(raw: Data, labelIDs: [String])] = []
        var threadListMaxResults: [Int] = []
        var messageListMaxResults: [Int] = []
        var timedCalls: [(at: Date, call: String)] = []
        var stamped = 0
    }

    let labels: LabelFakeGmail
    let sync = Mutex(SyncState())
    let now: @Sendable () -> Date

    init(labels: LabelFakeGmail = LabelFakeGmail(), me: String = "matti@example.fi",
         now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_791_190_830) }) {
        self.labels = labels
        self.now = now
        labels.update { $0.me = me }
    }

    var base: FakeGmail { labels.base }
    var me: String { base.state.withLock { $0.me } }
    var calls: [String] { labels.calls }
    var attempts: Int { sync.withLock { $0.attempts } }
    var historyID: UInt64 { sync.withLock { $0.historyID } }
    var inserted: [(raw: Data, labelIDs: [String])] { sync.withLock { $0.inserted } }
    var timedCalls: [(at: Date, call: String)] {
        stampNew()
        return sync.withLock { $0.timedCalls }
    }

    static let writePrefixes = ["modify ", "label create ", "label delete ", "insert", "batchModify ", "trash ", "untrash ", "send "]
    static func isWrite(_ call: String) -> Bool { writePrefixes.contains { call.hasPrefix($0) } }

    /// Calls that change the mailbox.
    var writes: [String] { calls.filter(Self.isWrite) }
    /// Same as `writes`; the name the label fakes use.
    var mutatingCalls: [String] { writes }
    func modifies(of threadID: String) -> [String] { calls.filter { $0.hasPrefix("modify \(threadID) ") } }
    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }

    /// `startHistoryId` of every `history.list` call, in order.
    var historyStarts: [String] {
        calls.filter { $0.hasPrefix("list history ") }.map { String($0.split(separator: " ")[2]) }
    }

    func update(_ body: (inout SyncState) -> Void) { sync.withLock { body(&$0) } }

    func resetCalls() {
        base.update { $0.calls = [] }
        sync.withLock { s in
            s.timedCalls = []
            s.stamped = 0
            s.attempts = 0
        }
    }

    /// Gmail's documented per-method units (docs/gmail-quota.md), keyed by this fake's call names.
    static func units(_ call: String) -> Int {
        let table: [(String, Int)] = [
            ("list history ", 2), ("list messages ", 5), ("list labels", 1), ("list labelIds ", 10), ("list ", 10),
            ("thread headers ", 40), ("thread labels ", 40), ("message headers ", 20), ("insert", 25), ("modify ", 10),
            ("label create ", 5), ("label delete ", 5), ("profile", 1), ("sendAs", 1), ("count label ", 1),
            ("batchModify ", 50),
        ]
        return table.first { call.hasPrefix($0.0) }?.1 ?? 40
    }

    static func units(_ calls: [String]) -> Int { calls.reduce(0) { $0 + units($1) } }

    // MARK: - Server-side helpers (no call recorded)

    /// An incoming (or, with other labels, any) message arrives in `threadID` at `date`. Creates the thread if
    /// needed and, unless `inHistory` is false, adds one `messagesAdded` record. Returns the message id.
    @discardableResult
    func deliver(_ threadID: String, from: String = "Anna Ahola <anna@example.fi>", subject: String = "Hei",
                 headers: [String: String] = [:], labels labelIDs: Set<String> = ["INBOX", "UNREAD"],
                 at date: Date? = nil, inHistory: Bool = true) -> String {
        var all: [String: [String]] = ["from": [from], "subject": [subject], "to": [me]]
        for (name, value) in headers { all[name.lowercased(), default: []].append(value) }
        return add(threadID, headers: all, labelIDs: labelIDs, at: date ?? now(), inHistory: inHistory)
    }

    /// Matti sends a message in `threadID` (labels SENT, history record like Gmail's).
    @discardableResult
    func sendMail(_ threadID: String, to: [String], cc: [String] = [], at date: Date? = nil,
                  inHistory: Bool = true, extraLabels: Set<String> = []) -> String {
        var all: [String: [String]] = ["from": [me], "subject": ["Re: hei"], "to": [to.joined(separator: ", ")]]
        if !cc.isEmpty { all["cc"] = [cc.joined(separator: ", ")] }
        return add(threadID, headers: all, labelIDs: Set(["SENT"]).union(extraLabels), at: date ?? now(), inHistory: inHistory)
    }

    /// The thread disappears (deleted forever): every later read answers 404.
    func removeThread(_ id: String) {
        base.update { $0.threads[id] = nil }
    }

    /// Something unrelated changed in the mailbox (a read/unread toggle): only `historyId` moves.
    func bumpHistory(by n: UInt64 = 1) {
        sync.withLock { $0.historyID += n }
    }

    func labelNames(of threadID: String) -> Set<String> { labels.labelNames(of: threadID) }

    /// Label names of one message (IDs mapped like `LabelFakeGmail.labelNames`).
    func labelNames(ofMessage messageID: String) -> Set<String> {
        let ids = base.state.withLock { s in
            s.threads.values.flatMap(\.messages).first { $0.id == messageID }?.labelIDs ?? []
        }
        let names = labels.labelState.withLock { s in Dictionary(s.labels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
        return Set(ids.map { names[$0] ?? $0 })
    }

    private func add(_ threadID: String, headers: [String: [String]], labelIDs: Set<String>, at date: Date,
                     inHistory: Bool) -> String {
        var messageID = ""
        base.update { s in
            var thread = s.threads[threadID] ?? MailThread(id: threadID, messages: [])
            messageID = "\(threadID)-m\(thread.messages.count + 1)"
            let from = headers["from"]?.first.flatMap { AddressParser.parseList($0).first }
            thread.messages.append(Message(
                id: messageID, threadID: threadID, from: from, replyTo: [], to: [], cc: [], date: date,
                subject: headers["subject"]?.first ?? "", snippet: "…", textBody: nil, htmlBody: nil, attachments: [],
                labelIDs: labelIDs, messageIDHeader: "<\(messageID)@example.fi>", references: nil
            ))
            s.threads[threadID] = thread
        }
        let id = messageID
        sync.withLock { s in
            s.meta[id] = Meta(headers: headers, internalDate: date)
            s.historyID += 1
            if inHistory {
                s.records.append(Record(id: s.historyID, added: [AddedMessage(id: id, threadID: threadID, labelIDs: labelIDs)]))
            }
        }
        return id
    }

    // MARK: - Recording

    /// Counts the attempt and refuses it while `failAll` is set.
    private func gate() throws {
        let error = sync.withLock { s -> (any Error)? in
            s.attempts += 1
            return s.failAll
        }
        if let error { throw error }
    }

    /// Same semantics as `FakeGmail.record`: append, then fail if offline or the op is in `failing`.
    private func record(_ call: String, op: String) throws {
        try base.state.withLock { s in
            s.calls.append(call)
            if s.offline { throw GmailError.offline }
            if s.failing.contains(op) { throw GmailError.http(500, "fail") }
        }
    }

    /// Stamps calls recorded since the last stamp with `now()`. Lock order: `sync`, then the base fake.
    private func stampNew() {
        let at = now()
        let base = self.base
        sync.withLock { s in
            let calls = base.state.withLock { $0.calls }
            guard calls.count > s.stamped else { return }
            s.timedCalls += calls[s.stamped...].map { (at: at, call: $0) }
            s.stamped = calls.count
        }
    }

    // MARK: - Search

    private func searchNames() -> [String: String] {
        labels.labelState.withLock { s in
            Dictionary(s.labels.map { ($0.id, $0.name.lowercased().replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")) },
                       uniquingKeysWith: { a, _ in a })
        }
    }

    private func matches(_ m: Message, terms: [Substring], names: [String: String], meta: [String: Meta]) -> Bool {
        let date = meta[m.id]?.internalDate ?? m.date
        let labelNames = Set(m.labelIDs.map { names[$0] ?? $0.lowercased() })
        for term in terms {
            if term == "in:inbox" {
                if !m.labelIDs.contains("INBOX") { return false }
            } else if term == "in:sent" {
                if !m.labelIDs.contains("SENT") { return false }
            } else if term.hasPrefix("after:"), let epoch = TimeInterval(term.dropFirst(6)) {
                if date.timeIntervalSince1970 < epoch { return false }
            } else if term.hasPrefix("newer_than:"), term.hasSuffix("d"), let days = Double(term.dropFirst(11).dropLast()) {
                if date <= now().addingTimeInterval(-days * 86_400) { return false }
            } else if term.hasPrefix("-label:") {
                if labelNames.contains(String(term.dropFirst(7)).lowercased()) { return false }
            } else if term.hasPrefix("label:") {
                if !labelNames.contains(String(term.dropFirst(6)).lowercased()) { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Messages matching `query`, newest first.
    private func messages(matching query: String) -> [Message] {
        let terms = query.split(separator: " ")
        let names = searchNames()
        let meta = sync.withLock { $0.meta }
        let all = base.state.withLock { s in s.threads.values.flatMap(\.messages) }
        func date(_ m: Message) -> Date { meta[m.id]?.internalDate ?? m.date }
        return all.filter { matches($0, terms: terms, names: names, meta: meta) }
            .sorted { date($0) != date($1) ? date($0) > date($1) : $0.id > $1.id }
    }

    /// Threads with at least one matching message, newest match first.
    private func threadIDs(matching query: String) -> [String] {
        var seen: Set<String> = []
        return messages(matching: query).compactMap { seen.insert($0.threadID).inserted ? $0.threadID : nil }
    }

    // MARK: - GmailSyncAPI

    func profile() async throws -> GmailProfile {
        try gate()
        defer { stampNew() }
        try record("profile", op: "profile")
        return GmailProfile(email: me, historyID: String(historyID))
    }

    func history(startHistoryID: String, pageToken: String?, maxResults: Int) async throws -> HistoryPage {
        try gate()
        defer { stampNew() }
        try record("list history \(startHistoryID) \(pageToken ?? "-")", op: "history")
        let start = UInt64(startHistoryID) ?? 0
        return try sync.withLock { s throws -> HistoryPage in
            if !s.historyErrors.isEmpty { throw s.historyErrors.removeFirst() }
            if let below = s.expiredBelow, start < below { throw GmailSyncError.historyExpired }
            let after = pageToken.flatMap { UInt64($0) } ?? start
            let lag = s.lagAfter
            let visible = s.records.filter { r in r.id > after && (lag.map { r.id <= $0 } ?? true) }
            let size = min(maxResults, s.historyPageSize ?? maxResults)
            let page = Array(visible.prefix(size))
            let last = page.last.map { String($0.id) }
            return HistoryPage(added: page.flatMap(\.added), lastRecordID: last, historyID: String(s.historyID),
                               nextPageToken: visible.count > page.count ? last : nil)
        }
    }

    func threadHeaders(id: String, headers: [String]) async throws -> ThreadHeaders {
        try gate()
        defer { stampNew() }
        try record("thread headers \(id)", op: "threadHeaders")
        let injected = sync.withLock { s -> (any Error)? in
            if let always = s.failingThreadHeaders[id] { return always }
            guard var queue = s.threadHeaderErrors[id], !queue.isEmpty else { return nil }
            let error = queue.removeFirst()
            s.threadHeaderErrors[id] = queue
            return error
        }
        if let injected { throw injected }
        guard let thread = base.state.withLock({ $0.threads[id] }) else { throw GmailError.http(404, id) }
        let wanted = Set(headers.map { $0.lowercased() })
        let (meta, historyID) = sync.withLock { ($0.meta, $0.historyID) }
        let messages = thread.messages.map { m in
            HeaderMessage(id: m.id, labelIDs: m.labelIDs, internalDate: meta[m.id]?.internalDate ?? m.date,
                          headers: (meta[m.id]?.headers ?? [:]).filter { wanted.contains($0.key) })
        }
        return ThreadHeaders(threadID: id, historyID: String(historyID), messages: messages)
    }

    func listMessageIDs(query: String, pageToken: String?, maxResults: Int) async throws -> MessageIDPage {
        try gate()
        defer { stampNew() }
        try record("list messages \(query) \(pageToken ?? "-")", op: "listMessages")
        let injected = sync.withLock { s -> (any Error)? in
            s.messageListMaxResults.append(maxResults)
            return s.messageListErrors.removeValue(forKey: pageToken ?? "-")
        }
        if let injected { throw injected }
        let ids = messages(matching: query).map(\.id)
        let offset = pageToken.flatMap { Int($0) } ?? 0
        let size = min(maxResults, sync.withLock { $0.messagePageSize } ?? maxResults)
        let slice = Array(ids.dropFirst(offset).prefix(size))
        return MessageIDPage(ids: slice, nextPageToken: offset + slice.count < ids.count ? String(offset + slice.count) : nil)
    }

    func messageHeaders(id: String, headers: [String]) async throws -> HeaderMessage {
        try gate()
        defer { stampNew() }
        try record("message headers \(id)", op: "messageHeaders")
        guard let m = base.state.withLock({ s in s.threads.values.flatMap(\.messages).first { $0.id == id } }) else {
            throw GmailError.http(404, id)
        }
        let wanted = Set(headers.map { $0.lowercased() })
        let meta = sync.withLock { $0.meta[id] }
        return HeaderMessage(id: id, labelIDs: m.labelIDs, internalDate: meta?.internalDate ?? m.date,
                             headers: (meta?.headers ?? [:]).filter { wanted.contains($0.key) })
    }

    /// Stores the message in a new thread "note-<n>" (labels as given, headers parsed from `raw`), lists it in
    /// history, like Gmail does for `messages.insert`, and returns the thread id.
    func insertMessage(raw: Data, labelIDs: [String]) async throws -> String {
        try gate()
        defer { stampNew() }
        try record("insert \(labelIDs.joined(separator: ","))", op: "insert")
        let threadID = sync.withLock { s -> String in
            s.inserted.append((raw, labelIDs))
            defer { s.nextNote += 1 }
            return "note-\(s.nextNote)"
        }
        _ = add(threadID, headers: Self.parseHeaders(raw), labelIDs: Set(labelIDs), at: now(), inHistory: true)
        return threadID                                                    // Gmail's threadId, as LiveGmailClient returns
    }

    /// RFC 822 header block → lowercased name → values (folded lines joined).
    static func parseHeaders(_ raw: Data) -> [String: [String]] {
        let text = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let block = text.components(separatedBy: "\n\n").first ?? ""
        var lines: [String] = []
        for line in block.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        var out: [String: [String]] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[name, default: []].append(value)
        }
        return out
    }

    /// Body of an RFC 822 message (after the first blank line).
    static func body(_ raw: Data) -> String {
        let text = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = text.range(of: "\n\n") else { return "" }
        return String(text[range.upperBound...])
    }

    // MARK: - GmailAPI and GmailLabelsAPI (delegated; history bumped on writes)

    func profileEmail() async throws -> String {
        try gate()
        defer { stampNew() }
        return try await labels.profileEmail()
    }

    func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try gate()
        defer { stampNew() }
        try record("list \(query) \(pageToken ?? "-")", op: "list")
        sync.withLock { $0.threadListMaxResults.append(maxResults) }
        let ids = threadIDs(matching: query)
        let offset = pageToken.flatMap { Int($0) } ?? 0
        let size = min(maxResults, sync.withLock { $0.threadPageSize } ?? maxResults)
        let slice = Array(ids.dropFirst(offset).prefix(size))
        return ThreadPage(ids: slice, nextPageToken: offset + slice.count < ids.count ? String(offset + slice.count) : nil,
                          estimate: ids.count)
    }

    func threadSummary(id: String, me: String?) async throws -> ThreadSummary {
        try gate()
        defer { stampNew() }
        return try await labels.threadSummary(id: id, me: me)
    }

    func thread(id: String) async throws -> MailThread {
        try gate()
        defer { stampNew() }
        return try await labels.thread(id: id)
    }

    func modify(threadID: String, add: [String], remove: [String]) async throws {
        try gate()
        defer { stampNew() }
        try await labels.modify(threadID: threadID, add: add, remove: remove)
        bumpHistory()
    }

    func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {
        try gate()
        defer { stampNew() }
        try await labels.batchModify(messageIDs: messageIDs, add: add, remove: remove)
        bumpHistory()
    }

    func trash(threadID: String) async throws {
        try gate()
        defer { stampNew() }
        try await labels.trash(threadID: threadID)
        bumpHistory()
    }

    func untrash(threadID: String) async throws {
        try gate()
        defer { stampNew() }
        try await labels.untrash(threadID: threadID)
        bumpHistory()
    }

    func send(raw: Data, threadID: String?) async throws {
        try gate()
        defer { stampNew() }
        try await labels.send(raw: raw, threadID: threadID)
    }

    func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try gate()
        defer { stampNew() }
        return try await labels.attachmentData(messageID: messageID, attachmentID: attachmentID)
    }

    func inboxUnreadCount() async throws -> Int {
        try gate()
        defer { stampNew() }
        return try await labels.inboxUnreadCount()
    }

    func unreadEstimate(query: String) async throws -> Int {
        try gate()
        defer { stampNew() }
        return try await labels.unreadEstimate(query: query)
    }

    func sendAsSignatures() async throws -> [SendAsSignature] {
        try gate()
        defer { stampNew() }
        return try await labels.sendAsSignatures()
    }

    func listLabels() async throws -> [GmailLabelInfo] {
        try gate()
        defer { stampNew() }
        return try await labels.listLabels()
    }

    func createLabel(name: String, visibility: LabelVisibility) async throws -> GmailLabelInfo {
        try gate()
        defer { stampNew() }
        return try await labels.createLabel(name: name, visibility: visibility)
    }

    func deleteLabel(id: String) async throws {
        try gate()
        defer { stampNew() }
        try await labels.deleteLabel(id: id)
        bumpHistory()
    }

    func listThreadIDs(labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try gate()
        defer { stampNew() }
        return try await labels.listThreadIDs(labelIDs: labelIDs, includeSpamTrash: includeSpamTrash, pageToken: pageToken, maxResults: maxResults)
    }

    func threadLabels(id: String, fresh: Bool) async throws -> ThreadLabels {
        try gate()
        defer { stampNew() }
        return try await labels.threadLabels(id: id, fresh: fresh)
    }

    func labelCounts(id: String) async throws -> LabelCounts {
        try gate()
        defer { stampNew() }
        return try await labels.labelCounts(id: id)
    }
}
