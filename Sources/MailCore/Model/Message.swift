import Foundation

public enum GmailLabel {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let starred = "STARRED"
    public static let trash = "TRASH"
}

public struct Attachment: Identifiable, Hashable, Sendable, Codable {
    public var id: String { "\(messageID)/\(partID)" }
    public var messageID: String
    public var partID: String
    public var attachmentID: String?
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Small attachments may be delivered inline in the payload instead of by id.
    public var inlineData: Data?

    public init(messageID: String, partID: String, attachmentID: String?, filename: String, mimeType: String, size: Int, inlineData: Data? = nil) {
        self.messageID = messageID
        self.partID = partID
        self.attachmentID = attachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.inlineData = inlineData
    }
}

public struct Message: Identifiable, Hashable, Sendable {
    public var id: String
    public var threadID: String
    public var from: MailAddress?
    public var replyTo: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var date: Date
    public var subject: String
    public var snippet: String
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [Attachment]
    public var labelIDs: Set<String>
    public var messageIDHeader: String?
    public var references: String?

    public var isUnread: Bool { labelIDs.contains(GmailLabel.unread) }

    /// Plain text used when quoting in replies and forwards.
    public var plainTextForQuoting: String {
        if let textBody, !textBody.isEmpty { return textBody }
        if let htmlBody { return HTMLText.plainText(fromHTML: htmlBody) }
        return snippet
    }
}

public struct MailThread: Identifiable, Hashable, Sendable {
    public var id: String
    public var messages: [Message]

    public var subject: String { messages.first?.subject ?? "" }
    public var labelIDs: Set<String> { messages.reduce(into: Set()) { $0.formUnion($1.labelIDs) } }
    public var isUnread: Bool { messages.contains(where: \.isUnread) }
}

public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var subject: String
    public var sender: String
    public var snippet: String
    public var date: Date
    public var labelIDs: Set<String>
    public var hasAttachments: Bool
    public var messageCount: Int
    /// The thread's message ids when the row was fetched; empty when unknown. Bulk actions use
    /// them for `messages.batchModify`.
    public var messageIDs: [String]

    public var isUnread: Bool { labelIDs.contains(GmailLabel.unread) }
    public var isStarred: Bool { labelIDs.contains(GmailLabel.starred) }

    public init(id: String, subject: String, sender: String, snippet: String, date: Date, labelIDs: Set<String>, hasAttachments: Bool, messageCount: Int, messageIDs: [String] = []) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.snippet = snippet
        self.date = date
        self.labelIDs = labelIDs
        self.hasAttachments = hasAttachments
        self.messageCount = messageCount
        self.messageIDs = messageIDs
    }
}
