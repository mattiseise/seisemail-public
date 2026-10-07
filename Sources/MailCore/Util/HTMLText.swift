import Foundation

public enum HTMLText {
    public static func plainText(fromHTML html: String) -> String {
        var s = html
        s = s.replacing(/(?is)<(style|script|head)\b.*?<\/\1\s*>/, with: "")
        s = s.replacing(/(?i)<br\s*\/?>/, with: "\n")
        s = s.replacing(/(?i)<\/(p|div|tr|li|h[1-6]|blockquote)\s*>/, with: "\n")
        s = s.replacing(/<[^>]*>/, with: "")
        s = decodeEntities(s)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/[ \t\u{00A0}]+/, with: " ").trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty ?? true { continue }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "auml": "ä", "ouml": "ö", "aring": "å", "Auml": "Ä", "Ouml": "Ö", "Aring": "Å",
        "euro": "€", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacing(/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/) { match -> String in
            let body = String(match.1)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let v = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { return String(Character(u)) }
            } else if body.hasPrefix("#") {
                if let v = UInt32(body.dropFirst()), let u = Unicode.Scalar(v) { return String(Character(u)) }
            } else if let r = named[body] ?? HTMLEntities.table[body] {
                return r
            }
            return String(match.0)
        }
    }
}
