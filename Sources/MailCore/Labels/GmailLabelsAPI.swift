import Foundation

public struct GmailLabelInfo: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable {
        case system, user
    }

    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// Labels of one thread, per message (oldest first). Gmail has no thread-level labels; the union is the thread's.
public struct ThreadLabels: Sendable, Equatable {
    public var threadID: String
    public var messageLabelIDs: [Set<String>]
    /// Returned by `format=minimal`; unused in Phase 1.
    public var historyID: String?

    public var labelIDs: Set<String> { messageLabelIDs.reduce(into: Set()) { $0.formUnion($1) } }

    public init(threadID: String, messageLabelIDs: [Set<String>], historyID: String?) {
        self.threadID = threadID
        self.messageLabelIDs = messageLabelIDs
        self.historyID = historyID
    }
}

/// Label endpoints. Refines GmailAPI so upstream conformers stay untouched; obtain it with `api as? any GmailLabelsAPI`.
public protocol GmailLabelsAPI: GmailAPI {
    /// GET users/me/labels: all system and user labels, no paging.
    func listLabels() async throws -> [GmailLabelInfo]
    /// POST users/me/labels with both visibility fields. Existing name → GmailError.http(409, _) (observed);
    /// reserved or invalid name → http(400, _) (documented).
    func createLabel(name: String, visibility: LabelVisibility) async throws -> GmailLabelInfo
    /// DELETE users/me/labels/{id}. Also strips the label from every message (documented). Missing → http(404, _).
    func deleteLabel(id: String) async throws
    /// GET users/me/threads with one `labelIds` per ID (AND), no `q`. `maxResults` is clamped to 1...500.
    func listThreadIDs(labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage
    /// GET users/me/threads/{id}?format=minimal. `fresh`: always from Gmail (and in the interactive
    /// quota lane); otherwise the read cache may answer while the thread's `historyId` from a recent
    /// list still matches. Only a read that decides a write may skip `fresh` if it re-reads fresh first.
    func threadLabels(id: String, fresh: Bool) async throws -> ThreadLabels
    /// GET users/me/labels/{id}: its thread counts (1 unit; a search count costs 10).
    func labelCounts(id: String) async throws -> LabelCounts
}

/// A label's `threadsTotal` and `threadsUnread` from labels.get.
public struct LabelCounts: Sendable, Equatable {
    public var threadsTotal: Int
    public var threadsUnread: Int

    public init(threadsTotal: Int, threadsUnread: Int) {
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
    }
}

extension GmailLabelsAPI {
    /// The view badges' count: unread threads carrying the label.
    public func labelThreadsUnread(id: String) async throws -> Int {
        try await labelCounts(id: id).threadsUnread
    }

    /// A fresh read (conventions §1: decide on the server's current labels).
    public func threadLabels(id: String) async throws -> ThreadLabels {
        try await threadLabels(id: id, fresh: true)
    }
}
