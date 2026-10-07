import Foundation

/// Untrusted text (subjects, sender names) and accidental secrets on their way into the daemon's files.
public enum Sanitize {
    public static let maxFieldLength = 120

    /// For one field of a log line or `decisions.jsonl`: C0/C1 controls and `\p{Cf}` stripped (no line
    /// breaks, no bidi overrides), backslashes and quotes escaped, at most `max` characters (an ellipsis
    /// marks a cut), and anything token-shaped redacted.
    public static func field(_ text: String, max: Int = maxFieldLength) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in secrets(text).unicodeScalars {
            let v = scalar.value
            if v < 0x20 || (0x7F...0x9F).contains(v) || scalar.properties.generalCategory == .format { continue }
            switch scalar {
            case "\\": scalars.append(contentsOf: "\\\\".unicodeScalars)
            case "\"": scalars.append(contentsOf: "\\\"".unicodeScalars)
            default: scalars.append(scalar)
            }
        }
        let clean = String(scalars)
        guard clean.count > max, max > 0 else { return clean }
        return String(clean.prefix(max - 1)) + "…"
    }

    /// A whole log line: controls stripped (newlines become spaces) and token-shaped text redacted.
    public static func line(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in secrets(text).unicodeScalars {
            let v = scalar.value
            if v == 0x0A || v == 0x0D || v == 0x09 { scalars.append(" "); continue }
            if v < 0x20 || (0x7F...0x9F).contains(v) || scalar.properties.generalCategory == .format { continue }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    public static let redacted = "[poistettu]"

    /// Redacts Google OAuth material by shape: access tokens (`ya29.…`), refresh tokens (`1//…`),
    /// authorization codes (`4/…`), client secrets (`GOCSPX-…`) and `code=`/`refresh_token=`/
    /// `access_token=`/`client_secret=` parameters. A second line of defence: nothing should log them.
    public static func secrets(_ text: String) -> String {
        var out = text
        for pattern in patterns {
            out = out.replacing(pattern) { _ in redacted }
        }
        return out
    }

    nonisolated(unsafe) private static let patterns: [Regex<Substring>] = [
        /(?i)(?:code|refresh_token|access_token|client_secret|id_token)=[^&\s"']+/,
        /ya29\.[A-Za-z0-9._\-]+/,
        /1\/\/[A-Za-z0-9._\-]{10,}/,
        /4\/[A-Za-z0-9._\-]{10,}/,
        /GOCSPX-[A-Za-z0-9._\-]+/,
    ]
}
