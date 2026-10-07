import Foundation

public struct ThreadPage: Sendable, Equatable {
    public var ids: [String]
    public var nextPageToken: String?
    public var estimate: Int

    public init(ids: [String], nextPageToken: String?, estimate: Int) {
        self.ids = ids
        self.nextPageToken = nextPageToken
        self.estimate = estimate
    }
}

public struct SendAsSignature: Sendable, Equatable {
    public var email: String
    public var html: String

    public init(email: String, html: String) {
        self.email = email
        self.html = html
    }
}

public enum GmailError: Error, Equatable, Sendable {
    case http(Int, String)
    case offline
    case decoding
    /// Gmail's per-user quota stayed exhausted through the quota transport's retries.
    case rateLimited
}

public protocol GmailAPI: Sendable {
    func profileEmail() async throws -> String
    func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage
    /// One `threads.list` request for background callers with their own backoff: a 429 or 5xx is
    /// thrown at once instead of retried (a 401 still refreshes the token once).
    func listThreadsOnce(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage
    func threadSummary(id: String, me: String?) async throws -> ThreadSummary
    func thread(id: String) async throws -> MailThread
    func modify(threadID: String, add: [String], remove: [String]) async throws
    /// Changes labels on messages (`messages.batchModify`, 50 units per call of up to 1,000 ids).
    /// Applied to every message id of a thread it equals `modify(threadID:)` on those messages.
    func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws
    func trash(threadID: String) async throws
    func untrash(threadID: String) async throws
    func send(raw: Data, threadID: String?) async throws
    func attachmentData(messageID: String, attachmentID: String) async throws -> Data
    func inboxUnreadCount() async throws -> Int
    func unreadEstimate(query: String) async throws -> Int
    func sendAsSignatures() async throws -> [SendAsSignature]
}

extension GmailAPI {
    /// Clients without their own retries need nothing else.
    public func listThreadsOnce(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await listThreads(query: query, pageToken: pageToken, maxResults: maxResults)
    }
}
