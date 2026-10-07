import Foundation

public struct OutgoingAttachment: Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct OutgoingMessage: Sendable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: String?
    public var attachments: [OutgoingAttachment]
    public var date: Date

    public init(from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], bcc: [MailAddress] = [], subject: String, body: String,
                inReplyTo: String? = nil, references: String? = nil, attachments: [OutgoingAttachment] = [], date: Date = Date()) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.date = date
    }
}

/// Builds an RFC 5322 message with CRLF line endings.
public enum MessageBuilder {
    public static let maxRawSize = 35 * 1024 * 1024

    public static func build(_ m: OutgoingMessage, boundary: String = "mak8r-\(UUID().uuidString)") -> Data {
        var headers: [String] = []
        func add(_ name: String, _ value: String) { headers.append(fold(name, clean(value))) }
        add("From", m.from.rfc5322)
        if !m.to.isEmpty { add("To", list(m.to)) }
        if !m.cc.isEmpty { add("Cc", list(m.cc)) }
        if !m.bcc.isEmpty { add("Bcc", list(m.bcc)) }
        add("Subject", EncodedWords.encode(clean(m.subject)))
        add("Date", rfc2822Date(m.date))
        let domain = m.from.email.split(separator: "@").last.map(String.init) ?? "localhost"
        add("Message-ID", "<\(UUID().uuidString)@\(domain)>")
        if let inReplyTo = m.inReplyTo { add("In-Reply-To", inReplyTo) }
        if let references = m.references { add("References", references) }
        add("MIME-Version", "1.0")

        let textPart = [
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            base64Lines(Data(normalizeNewlines(m.body).utf8)),
        ].joined(separator: "\r\n")

        var out: String
        if m.attachments.isEmpty {
            out = headers.joined(separator: "\r\n") + "\r\n" + textPart + "\r\n"
        } else {
            add("Content-Type", "multipart/mixed; boundary=\"\(boundary)\"")
            var parts = [textPart]
            for a in m.attachments {
                let filename = clean(a.filename).precomposedStringWithCanonicalMapping
                // Encoded words in the quoted parameter are what most clients read; RFC 2231
                // filename* is the standard form for the rest. Short ASCII names stay plain.
                let plain = filename.unicodeScalars.allSatisfy(\.isASCII) && filename.utf8.count <= maxPlainFilename
                let name = plain
                    ? filename.replacingOccurrences(of: "\"", with: "")
                    : EncodedWords.encodeWords(filename, bytesPerWord: filenameBytesPerWord, force: true).joined(separator: " ")
                var disposition = "attachment; filename=\"\(name)\""
                if !plain { disposition += "; " + extendedParameter("filename", filename).joined(separator: "; ") }
                parts.append([
                    fold("Content-Type", "\(clean(a.mimeType)); name=\"\(name)\""),
                    fold("Content-Disposition", disposition),
                    "Content-Transfer-Encoding: base64",
                    "",
                    base64Lines(a.data),
                ].joined(separator: "\r\n"))
            }
            out = headers.joined(separator: "\r\n") + "\r\n\r\n"
            for p in parts { out += "--\(boundary)\r\n\(p)\r\n" }
            out += "--\(boundary)--\r\n"
        }
        return Data(out.utf8)
    }

    /// RFC 5322 §2.1.1: lines SHOULD be at most 78 characters.
    static let maxLineLength = 78

    /// ASCII filenames up to this length are sent as a plain quoted string: the
    /// ` filename="…";` line then fits in 78 characters.
    static let maxPlainFilename = 64

    /// 39 bytes is a 64-character encoded word, so ` filename="<word>";` is 77 characters.
    static let filenameBytesPerWord = 39

    /// `Name: value`, folded before existing spaces so that lines stay within 78 characters
    /// where the value allows it. Removing the CRLFs gives back the value unchanged, and each
    /// continuation line starts with a space, so a cleaned value cannot inject a header.
    static func fold(_ name: String, _ value: String) -> String {
        var lines: [String] = []
        var current = "\(name):"
        for (i, segment) in value.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let fits = current.utf8.count + 1 + segment.utf8.count <= maxLineLength
            // The first segment may also start a continuation line (FWS after the colon),
            // which keeps e.g. a long Office MIME type within the limit.
            let canBreak = i > 0 || 1 + segment.utf8.count <= maxLineLength
            if fits || segment.isEmpty || !canBreak {
                current += " " + segment
            } else {
                lines.append(current)
                current = " " + segment
            }
        }
        lines.append(current)
        return lines.joined(separator: "\r\n")
    }

    /// `name*=UTF-8''…` (RFC 2231), split into `name*0*=`, `name*1*=`… continuations when
    /// one line would exceed 78 characters. Splits fall between characters, never inside one.
    static func extendedParameter(_ name: String, _ value: String) -> [String] {
        let single = "\(name)*=UTF-8''\(rfc2231(value))"
        if 1 + single.utf8.count <= maxLineLength { return [single] }
        var segments: [String] = []
        var current = ""
        func prefix() -> String { "\(name)*\(segments.count)*=" + (segments.isEmpty ? "UTF-8''" : "") }
        for scalar in value.unicodeScalars {
            let encoded = rfc2231(String(scalar))
            // Leading space, prefix, value and the ";" that separates it from the next one.
            if !current.isEmpty, 1 + prefix().utf8.count + current.utf8.count + encoded.utf8.count + 1 > maxLineLength {
                segments.append(prefix() + current)
                current = ""
            }
            current += encoded
        }
        segments.append(prefix() + current)
        return segments
    }

    /// Header values come partly from received mail; a CR/LF or other control character there
    /// would let a sender inject headers (e.g. a hidden Bcc) into our reply.
    static func clean(_ value: String) -> String {
        String(value.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) })
    }

    /// RFC 2231/5987 percent-encoding of UTF-8 bytes outside `attr-char`.
    static func rfc2231(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        return value.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    private static func list(_ addresses: [MailAddress]) -> String {
        addresses.map(\.rfc5322).joined(separator: ", ")
    }

    private static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func rfc2822Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}
