import Foundation

/// Notices when the user's own text mentions an attachment ("liitteenä", "attached", …).
public enum AttachmentReminder {
    public static func shouldWarn(_ draft: Draft) -> Bool {
        draft.attachments.isEmpty && mentionsAttachment(in: draft.body)
    }

    public static func mentionsAttachment(in body: String) -> Bool {
        ownText(body).contains(/(?i)\b(liite|liitte|ohessa|attach|enclos)/)
    }

    /// The part the user wrote: up to the signature or forwarded message, without quoted lines.
    static func ownText(_ body: String) -> String {
        var lines: [Substring] = []
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "-- " || line.hasPrefix("---------- Välitetty viesti") { break }
            if line.hasPrefix(">") || line.hasSuffix(" kirjoitti:") { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
