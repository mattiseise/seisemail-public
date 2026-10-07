import Foundation

// Fork (seisemail): read endpoints the Mac mini daemon needs on top of the label API
// (docs/design/phase2-daemon.md §4). Units are Google's per-method quota costs.

public struct GmailProfile: Sendable, Equatable {
    public var email: String
    /// The mailbox's current `historyId`.
    public var historyID: String

    public init(email: String, historyID: String) {
        self.email = email
        self.historyID = historyID
    }
}

/// One `messagesAdded` history record entry.
public struct AddedMessage: Sendable, Equatable {
    public var id: String
    public var threadID: String
    /// Labels at query time; a hint only (the daemon reads the thread fresh before deciding).
    public var labelIDs: Set<String>?

    public init(id: String, threadID: String, labelIDs: Set<String>? = nil) {
        self.id = id
        self.threadID = threadID
        self.labelIDs = labelIDs
    }
}

public struct HistoryPage: Sendable, Equatable {
    /// In record order.
    public var added: [AddedMessage]
    /// `id` of the page's last history record; nil when the page has no records.
    public var lastRecordID: String?
    /// The mailbox `historyId` at response time.
    public var historyID: String
    public var nextPageToken: String?

    public init(added: [AddedMessage], lastRecordID: String?, historyID: String, nextPageToken: String?) {
        self.added = added
        self.lastRecordID = lastRecordID
        self.historyID = historyID
        self.nextPageToken = nextPageToken
    }
}

/// A message read with `format=metadata`: labels, `internalDate` and the requested headers.
public struct HeaderMessage: Sendable, Equatable {
    public var id: String
    public var labelIDs: Set<String>
    public var internalDate: Date?
    /// Lowercased header name → values in message order.
    public var headers: [String: [String]]

    /// Header names are lowercased here, so callers may pass them in any case.
    public init(id: String, labelIDs: Set<String>, internalDate: Date?, headers: [String: [String]]) {
        self.id = id
        self.labelIDs = labelIDs
        self.internalDate = internalDate
        var lowered: [String: [String]] = [:]
        for (name, values) in headers.sorted(by: { $0.key < $1.key }) {
            lowered[name.lowercased(), default: []] += values
        }
        self.headers = lowered
    }

    /// The first value of `name`, case-insensitively.
    public func first(_ name: String) -> String? {
        headers[name.lowercased()]?.first
    }

    /// Every value of `name`, case-insensitively.
    public func all(_ name: String) -> [String] {
        headers[name.lowercased()] ?? []
    }
}

public struct ThreadHeaders: Sendable, Equatable {
    public var threadID: String
    public var historyID: String?
    /// Oldest first.
    public var messages: [HeaderMessage]

    public init(threadID: String, historyID: String?, messages: [HeaderMessage]) {
        self.threadID = threadID
        self.historyID = historyID
        self.messages = messages
    }

    /// Union of the messages' labels: the thread's labels.
    public var labelIDs: Set<String> { messages.reduce(into: Set()) { $0.formUnion($1.labelIDs) } }
}

public struct MessageIDPage: Sendable, Equatable {
    public var ids: [String]
    public var nextPageToken: String?

    public init(ids: [String], nextPageToken: String?) {
        self.ids = ids
        self.nextPageToken = nextPageToken
    }
}

public enum GmailSyncError: Error, Equatable, Sendable {
    /// `history.list` answered 404: the start id is older than Gmail keeps history.
    case historyExpired
}

/// The daemon's read API. Refines the label API, so one client value serves wakes, sorting and notes.
public protocol GmailSyncAPI: GmailLabelsAPI {
    /// `users.getProfile` (1 unit): address and current `historyId`.
    func profile() async throws -> GmailProfile
    /// `users.history.list` (2 units), `historyTypes=messageAdded`, no `labelId`.
    /// 404 → `GmailSyncError.historyExpired`.
    func history(startHistoryID: String, pageToken: String?, maxResults: Int) async throws -> HistoryPage
    /// `threads.get?format=metadata` (40 units) with `metadataHeaders`, always fresh from Gmail.
    func threadHeaders(id: String, headers: [String]) async throws -> ThreadHeaders
    /// `messages.list` (5 units).
    func listMessageIDs(query: String, pageToken: String?, maxResults: Int) async throws -> MessageIDPage
    /// `messages.get?format=metadata` (20 units).
    func messageHeaders(id: String, headers: [String]) async throws -> HeaderMessage
    /// `messages.insert` (25 units): puts `raw` into the mailbox without sending it. Returns the thread id
    /// (the message id when Gmail omits it), which `threads.modify` archives.
    func insertMessage(raw: Data, labelIDs: [String]) async throws -> String
}
