import Foundation

public enum ComposeFactory {
    public static func new(signature: Signature? = nil) -> Draft {
        Draft(body: lead(signature), signatureID: signature?.id)
    }

    public static func reply(to message: Message, in thread: MailThread, me: String, all: Bool, signature: Signature? = nil, timeZone: TimeZone = .current) -> Draft {
        let fromMe = message.from?.matches(me) ?? false
        var to: [MailAddress]
        var cc: [MailAddress] = []
        if fromMe {
            to = message.to
        } else if !message.replyTo.isEmpty {
            to = message.replyTo
        } else {
            to = message.from.map { [$0] } ?? []
        }
        if all {
            to += message.to
            cc = message.cc
        }
        to = unique(to.filter { !$0.matches(me) })
        cc = unique(cc.filter { c in !c.matches(me) && !to.contains { $0.matches(c.email) } })

        let references = [message.references, message.messageIDHeader].compactMap { $0 }.joined(separator: " ")
        return Draft(
            to: to.map(\.editableForm).joined(separator: ", "),
            cc: cc.map(\.editableForm).joined(separator: ", "),
            subject: prefixed("Re:", message.subject),
            body: lead(signature) + "\n\n" + attribution(for: message, timeZone: timeZone) + "\n" + quote(message.plainTextForQuoting),
            threadID: thread.id,
            inReplyTo: message.messageIDHeader,
            references: references.isEmpty ? nil : references,
            signatureID: signature?.id
        )
    }

    public static func forward(_ message: Message, in thread: MailThread, signature: Signature? = nil, timeZone: TimeZone = .current) -> Draft {
        var header = ["", "", "---------- Välitetty viesti ----------"]
        if let from = message.from { header.append("Lähettäjä: \(from.editableForm)") }
        header.append("Päivämäärä: \(finnishDate(message.date, timeZone: timeZone))")
        header.append("Aihe: \(message.subject)")
        if !message.to.isEmpty { header.append("Vastaanottaja: \(message.to.map(\.editableForm).joined(separator: ", "))") }
        header.append("")
        return Draft(
            subject: prefixed("Fwd:", message.subject),
            body: lead(signature) + header.joined(separator: "\n") + "\n" + message.plainTextForQuoting,
            attachments: message.attachments.map { .gmail($0) },
            signatureID: signature?.id
        )
    }

    /// Signature block placed before quoted or forwarded text, or "" without a signature.
    private static func lead(_ signature: Signature?) -> String {
        signature.map { "\n\n" + SignatureInserter.block($0) } ?? ""
    }

    public static func attribution(for message: Message, timeZone: TimeZone = .current) -> String {
        let name = message.from?.displayName ?? "Tuntematon"
        return "\(finnishDate(message.date, timeZone: timeZone)) \(name) kirjoitti:"
    }

    static func finnishDate(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.weekday, .day, .month, .year, .hour, .minute], from: date)
        let weekdays = ["Su", "Ma", "Ti", "Ke", "To", "Pe", "La"]
        let weekday = weekdays[(c.weekday ?? 1) - 1]
        return String(format: "%@ %d.%d.%d klo %d.%02d", weekday, c.day ?? 0, c.month ?? 0, c.year ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    private static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    private static func unique(_ list: [MailAddress]) -> [MailAddress] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.email.lowercased()).inserted }
    }
}
