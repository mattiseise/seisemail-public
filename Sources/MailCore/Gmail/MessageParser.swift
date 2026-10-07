import Foundation

public enum MessageParser {
    public static func thread(_ dto: GmailThreadDTO) -> MailThread {
        MailThread(id: dto.id, messages: (dto.messages ?? []).map(message))
    }

    public static func message(_ dto: GmailMessageDTO) -> Message {
        let payload = dto.payload
        let header = { (name: String) in payload?.header(name) }
        var text: String?
        var html: String?
        var attachments: [Attachment] = []
        if let payload {
            walk(payload, messageID: dto.id, text: &text, html: &html, attachments: &attachments)
        }
        return Message(
            id: dto.id,
            threadID: dto.threadId,
            from: header("From").flatMap { AddressParser.parseList($0).first },
            replyTo: header("Reply-To").map(AddressParser.parseList) ?? [],
            to: header("To").map(AddressParser.parseList) ?? [],
            cc: header("Cc").map(AddressParser.parseList) ?? [],
            date: date(dto),
            subject: header("Subject").map(EncodedWords.decode) ?? "",
            snippet: HTMLText.decodeEntities(dto.snippet ?? ""),
            textBody: text,
            htmlBody: html,
            attachments: attachments,
            labelIDs: Set(dto.labelIds ?? []),
            messageIDHeader: header("Message-ID") ?? header("Message-Id"),
            references: header("References")
        )
    }

    public static func summary(_ dto: GmailThreadDTO, me: String?) -> ThreadSummary {
        let messages = dto.messages ?? []
        let last = messages.last
        let fromMe: (GmailMessageDTO) -> Bool = { m in
            guard let me, let from = m.payload?.header("From").flatMap({ AddressParser.parseList($0).first }) else { return false }
            return from.matches(me)
        }
        let senderMessage = messages.last(where: { !fromMe($0) })
        let sender = senderMessage?.payload?.header("From")
            .flatMap { AddressParser.parseList($0).first?.displayName } ?? "Minä"
        let hasAttachments = messages.contains { m in
            (m.payload?.header("Content-Type") ?? m.payload?.mimeType ?? "").lowercased().hasPrefix("multipart/mixed")
        }
        let labels = messages.reduce(into: Set<String>()) { $0.formUnion($1.labelIds ?? []) }
        let subject = messages.first?.payload?.header("Subject").map(EncodedWords.decode) ?? ""
        return ThreadSummary(
            id: dto.id,
            subject: subject,
            sender: sender,
            snippet: HTMLText.decodeEntities(last?.snippet ?? dto.snippet ?? ""),
            date: last.map(date) ?? .distantPast,
            labelIDs: labels,
            hasAttachments: hasAttachments,
            messageCount: messages.count,
            messageIDs: messages.map(\.id)
        )
    }

    private static func date(_ dto: GmailMessageDTO) -> Date {
        guard let ms = dto.internalDate.flatMap(Double.init) else { return .distantPast }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func walk(_ part: GmailPartDTO, messageID: String, text: inout String?, html: inout String?, attachments: inout [Attachment]) {
        let mime = (part.mimeType ?? "").lowercased()
        let filename = part.filename ?? ""
        if let parts = part.parts, !parts.isEmpty {
            for child in parts {
                walk(child, messageID: messageID, text: &text, html: &html, attachments: &attachments)
            }
            return
        }
        let isAttachment = !filename.isEmpty || part.body?.attachmentId != nil
        if isAttachment {
            attachments.append(Attachment(
                messageID: messageID,
                // A message that is only an attachment has partId "" at the top; real ids are digits
                // and dots, so "root" can't collide, and the attachment link needs a non-empty part.
                partID: part.partId.map { $0.isEmpty ? "root" : $0 } ?? UUID().uuidString,
                attachmentID: part.body?.attachmentId,
                filename: filename.isEmpty ? "liite" : EncodedWords.decode(filename),
                mimeType: mime.isEmpty ? "application/octet-stream" : mime,
                size: part.body?.size ?? 0,
                inlineData: part.body?.data.flatMap(Base64URL.decode)
            ))
            return
        }
        guard let data = part.body?.data.flatMap(Base64URL.decode) else { return }
        let charset = part.header("Content-Type").flatMap(charsetParameter)
        let decoded = Charset.string(from: data, charset: charset, messageID: messageID)
        if mime == "text/plain", text == nil {
            text = decoded
        } else if mime == "text/html", html == nil {
            html = decoded
        }
    }

    static func charsetParameter(_ contentType: String) -> String? {
        guard let match = contentType.firstMatch(of: /(?i)charset\s*=\s*"?([^";\s]+)"?/) else { return nil }
        return String(match.1)
    }
}
