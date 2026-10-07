import Foundation
import MailCore

public enum DaemonError: Error, Equatable, Sendable {
    /// The daemon never sends, trashes or untrashes mail, in any mode.
    case forbiddenWrite(String)
}

/// A write the shadow gate swallowed.
public enum ShadowWrite: Sendable, Equatable {
    case modify(thread: String, add: [String], remove: [String])
    case createLabel(String)
    case deleteLabel(String)
    case insert
    case batchModify(Int)

    /// One line for the log or the CLI: IDs and counts only, never a label name chosen by a sender.
    public var summary: String {
        switch self {
        case .modify(let thread, let add, let remove):
            "modify \(thread) add=\(add.joined(separator: ",")) remove=\(remove.joined(separator: ","))"
        case .createLabel: "labels.create"
        case .deleteLabel(let id): "labels.delete \(id)"
        case .insert: "messages.insert"
        case .batchModify(let n): "batchModify \(n)"
        }
    }
}

public enum DaemonGmailMode: Sendable {
    case live
    /// Writes are recorded and not sent (D10). Reads pass through.
    case shadow(record: @Sendable (ShadowWrite) -> Void)

    public var isShadow: Bool {
        if case .shadow = self { return true }
        return false
    }
}

/// The mode gate around one account's client (D10). Reads pass through in every mode.
/// `send`, `trash` and `untrash` always throw `DaemonError.forbiddenWrite`. In shadow, modify/batchModify/
/// deleteLabel/insert record and return, and createLabel returns `GmailLabelInfo(id: "SHADOW:<name>")`,
/// so a shadow `LabelDirectory` never creates a real label.
public struct DaemonGmail: GmailSyncAPI {
    public static let shadowIDPrefix = "SHADOW:"

    private let base: any GmailSyncAPI
    public let mode: DaemonGmailMode

    /// `base` is normally the account's `LiveGmailClient`; tests pass a fake.
    public init(_ base: any GmailSyncAPI, mode: DaemonGmailMode) {
        self.base = base
        self.mode = mode
    }

    private func shadow(_ write: ShadowWrite) -> Bool {
        guard case .shadow(let record) = mode else { return false }
        record(write)
        return true
    }

    // MARK: Forbidden

    public func send(raw: Data, threadID: String?) async throws { throw DaemonError.forbiddenWrite("send") }
    public func trash(threadID: String) async throws { throw DaemonError.forbiddenWrite("trash") }
    public func untrash(threadID: String) async throws { throw DaemonError.forbiddenWrite("untrash") }

    // MARK: Gated writes

    public func modify(threadID: String, add: [String], remove: [String]) async throws {
        if shadow(.modify(thread: threadID, add: add, remove: remove)) { return }
        try await base.modify(threadID: threadID, add: add, remove: remove)
    }

    public func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {
        if shadow(.batchModify(messageIDs.count)) { return }
        try await base.batchModify(messageIDs: messageIDs, add: add, remove: remove)
    }

    public func createLabel(name: String, visibility: LabelVisibility) async throws -> GmailLabelInfo {
        if shadow(.createLabel(name)) { return GmailLabelInfo(id: Self.shadowIDPrefix + name, name: name, kind: .user) }
        return try await base.createLabel(name: name, visibility: visibility)
    }

    public func deleteLabel(id: String) async throws {
        if shadow(.deleteLabel(id)) { return }
        try await base.deleteLabel(id: id)
    }

    public func insertMessage(raw: Data, labelIDs: [String]) async throws -> String {
        if shadow(.insert) { return Self.shadowIDPrefix + "insert" }
        return try await base.insertMessage(raw: raw, labelIDs: labelIDs)
    }

    // MARK: Reads

    public func profileEmail() async throws -> String { try await base.profileEmail() }
    public func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await base.listThreads(query: query, pageToken: pageToken, maxResults: maxResults)
    }
    public func listThreadsOnce(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await base.listThreadsOnce(query: query, pageToken: pageToken, maxResults: maxResults)
    }
    public func threadSummary(id: String, me: String?) async throws -> ThreadSummary { try await base.threadSummary(id: id, me: me) }
    public func thread(id: String) async throws -> MailThread { try await base.thread(id: id) }
    public func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try await base.attachmentData(messageID: messageID, attachmentID: attachmentID)
    }
    public func inboxUnreadCount() async throws -> Int { try await base.inboxUnreadCount() }
    public func unreadEstimate(query: String) async throws -> Int { try await base.unreadEstimate(query: query) }
    public func sendAsSignatures() async throws -> [SendAsSignature] { try await base.sendAsSignatures() }
    public func listLabels() async throws -> [GmailLabelInfo] { try await base.listLabels() }
    public func listThreadIDs(labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await base.listThreadIDs(labelIDs: labelIDs, includeSpamTrash: includeSpamTrash, pageToken: pageToken, maxResults: maxResults)
    }
    public func threadLabels(id: String, fresh: Bool) async throws -> ThreadLabels { try await base.threadLabels(id: id, fresh: fresh) }
    public func labelCounts(id: String) async throws -> LabelCounts { try await base.labelCounts(id: id) }
    public func profile() async throws -> GmailProfile { try await base.profile() }
    public func history(startHistoryID: String, pageToken: String?, maxResults: Int) async throws -> HistoryPage {
        try await base.history(startHistoryID: startHistoryID, pageToken: pageToken, maxResults: maxResults)
    }
    public func threadHeaders(id: String, headers: [String]) async throws -> ThreadHeaders {
        try await base.threadHeaders(id: id, headers: headers)
    }
    public func listMessageIDs(query: String, pageToken: String?, maxResults: Int) async throws -> MessageIDPage {
        try await base.listMessageIDs(query: query, pageToken: pageToken, maxResults: maxResults)
    }
    public func messageHeaders(id: String, headers: [String]) async throws -> HeaderMessage {
        try await base.messageHeaders(id: id, headers: headers)
    }
}
