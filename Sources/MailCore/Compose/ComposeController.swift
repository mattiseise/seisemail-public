import Foundation
import UniformTypeIdentifiers

public enum ComposeError: Error, Equatable, Sendable {
    case noRecipients
    case tooLarge
    case invalidAddress(String)
}

public struct ComposeController: Sendable {
    let api: GmailAPI
    let drafts: DraftStore
    let readFile: @Sendable (URL) throws -> Data

    public init(api: GmailAPI, drafts: DraftStore, readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.api = api
        self.drafts = drafts
        self.readFile = readFile
    }

    /// Builds, size-checks and sends the draft. The local draft file is removed only after Gmail accepts it.
    public func send(_ draft: Draft, from me: String) async throws {
        try Self.validate(draft)
        let to = AddressParser.parseList(draft.to)
        let cc = AddressParser.parseList(draft.cc)
        let bcc = AddressParser.parseList(draft.bcc)

        var attachments: [OutgoingAttachment] = []
        var estimatedSize = draft.body.utf8.count
        for item in draft.attachments {
            let attachment: OutgoingAttachment
            switch item {
            case .file(let url):
                let data = try readFile(url)
                attachment = OutgoingAttachment(filename: url.lastPathComponent, mimeType: Self.mimeType(forFilename: url.lastPathComponent), data: data)
            case .gmail(let a):
                let data: Data
                if let inline = a.inlineData {
                    data = inline
                } else if let attachmentID = a.attachmentID {
                    data = try await api.attachmentData(messageID: a.messageID, attachmentID: attachmentID)
                } else {
                    continue
                }
                attachment = OutgoingAttachment(filename: a.filename, mimeType: a.mimeType, data: data)
            }
            estimatedSize += attachment.data.count * 4 / 3
            guard estimatedSize <= MessageBuilder.maxRawSize else { throw ComposeError.tooLarge }
            attachments.append(attachment)
        }

        let raw = MessageBuilder.build(OutgoingMessage(
            from: MailAddress(name: nil, email: me),
            to: to, cc: cc, bcc: bcc,
            subject: draft.subject,
            body: draft.body,
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            attachments: attachments
        ))
        guard raw.count <= MessageBuilder.maxRawSize else { throw ComposeError.tooLarge }
        try await api.send(raw: raw, threadID: draft.threadID)
        drafts.delete(id: draft.id)
    }

    /// Checks the recipients; run before an undo-send delay so mistakes show up at once.
    public static func validate(_ draft: Draft) throws {
        let all = AddressParser.parseList(draft.to) + AddressParser.parseList(draft.cc) + AddressParser.parseList(draft.bcc)
        guard !all.isEmpty else { throw ComposeError.noRecipients }
        if let invalid = all.first(where: { !$0.isValid }) {
            throw ComposeError.invalidAddress(invalid.email)
        }
    }

    public static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext.lowercased()) else { return "application/octet-stream" }
        return type.preferredMIMEType ?? "application/octet-stream"
    }
}
