import Foundation

public struct MailAddress: Hashable, Sendable, Codable {
    public var name: String?
    public var email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return email
    }

    /// Wire form for outgoing headers: non-ASCII names become RFC 2047 encoded words.
    public var rfc5322: String {
        guard let name, !name.isEmpty else { return email }
        let encoded = EncodedWords.encode(name)
        if encoded != name { return "\(encoded) <\(email)>" }
        return editableForm
    }

    /// Human-readable form for compose fields and quoted headers: the name stays as typed
    /// (`"Mäkinen Åsa" <asa@x.fi>`). `AddressParser.parseList` reads it back, and
    /// `MessageBuilder` encodes it with `rfc5322` when the message is sent.
    public var editableForm: String {
        guard let name, !name.isEmpty else { return email }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(email)>"
    }

    public var isValid: Bool {
        email.wholeMatch(of: /[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+/) != nil
    }

    public func matches(_ other: String) -> Bool {
        email.caseInsensitiveCompare(other) == .orderedSame
    }
}

public enum AddressParser {
    public static func parseList(_ input: String) -> [MailAddress] {
        splitTopLevel(input).compactMap(parseOne)
    }

    private static func splitTopLevel(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var escaped = false
        for c in input {
            if escaped { current.append(c); escaped = false; continue }
            switch c {
            case "\\" where inQuotes: escaped = true; current.append(c)
            case "\"": inQuotes.toggle(); current.append(c)
            case "<" where !inQuotes: inAngle = true; current.append(c)
            case ">" where !inQuotes: inAngle = false; current.append(c)
            case ",", ";":
                if inQuotes || inAngle { current.append(c) } else { parts.append(current); current = "" }
            default: current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    private static func parseOne(_ raw: String) -> MailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
            let email = s[s.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = s[..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            name = EncodedWords.decode(name)
            return MailAddress(name: name.isEmpty ? nil : name, email: email)
        }
        return MailAddress(name: nil, email: s)
    }
}
