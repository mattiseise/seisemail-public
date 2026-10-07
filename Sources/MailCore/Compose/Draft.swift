import Foundation

public struct Draft: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var to: String
    public var cc: String
    public var bcc: String
    public var subject: String
    public var body: String
    public var threadID: String?
    public var inReplyTo: String?
    public var references: String?
    public var attachments: [DraftAttachment]
    public var updatedAt: Date
    /// Sending account; nil in drafts saved before multiple accounts.
    public var account: String?
    /// Signature placed in the body when the draft was created or last switched; nil for none.
    public var signatureID: UUID?

    public init(id: UUID = UUID(), to: String = "", cc: String = "", bcc: String = "", subject: String = "", body: String = "",
                threadID: String? = nil, inReplyTo: String? = nil, references: String? = nil,
                attachments: [DraftAttachment] = [], updatedAt: Date = Date(), account: String? = nil, signatureID: UUID? = nil) {
        self.id = id
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.threadID = threadID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.updatedAt = updatedAt
        self.account = account
        self.signatureID = signatureID
    }

    /// Everything the user edits; excludes identity and timestamps.
    public struct Content: Hashable, Sendable {
        var to, cc, bcc, subject, body: String
        var attachments: [DraftAttachment]
    }

    public var content: Content {
        Content(to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachments: attachments)
    }

    public var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

public enum DraftAttachment: Codable, Hashable, Sendable, Identifiable {
    case file(URL)
    case gmail(Attachment)

    public var id: String {
        switch self {
        case .file(let url): "file:\(url.path)"
        case .gmail(let a): "gmail:\(a.id)"
        }
    }

    public var filename: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .gmail(let a): a.filename
        }
    }
}
