import Foundation
import MailCore

/// Headers the sorter reads with every thread (`threads.get?format=metadata`, design §6.4 `H`).
public enum DaemonHeaders {
    public static let ownNote = "X-Mak8r-Daemon"
    public static let thread = ["From", "To", "Cc", "Subject", "List-Unsubscribe", "List-Id", "Auto-Submitted", ownNote]
    public static let recipients = ["To", "Cc"]
}

/// The decider's normalised inputs for the rules (design §7.1). Message content is untrusted input:
/// nothing here is interpreted beyond these normalisations.
public struct MessageFacts: Sendable, Equatable {
    /// From's first valid address, comments stripped, trimmed and lowercased. nil when From has none.
    public var fromAddress: String?
    /// The display name of that address, decoded (RFC 2047).
    public var fromName: String?
    /// Decoded, ≤ 1,000 characters, NFC, `\p{Cf}` removed, lowercased.
    public var subject: String
    public var subjectTokens: [String]
    /// The display name plus the address's local part, tokenised like the subject. The domain is ignored.
    public var senderTokens: [String]
    /// `Auto-Submitted` normalised; nil when missing or empty.
    public var autoSubmitted: String?
    /// Lowercased names of headers with a non-empty trimmed value.
    public var presentHeaders: Set<String>
    /// The decider's user-label names (from the snapshot).
    public var userLabelNames: [String]
    /// The decider's system label IDs.
    public var systemLabelIDs: Set<String>

    public init(fromAddress: String?, fromName: String?, subject: String, subjectTokens: [String], senderTokens: [String],
                autoSubmitted: String?, presentHeaders: Set<String>, userLabelNames: [String], systemLabelIDs: Set<String>) {
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.subject = subject
        self.subjectTokens = subjectTokens
        self.senderTokens = senderTokens
        self.autoSubmitted = autoSubmitted
        self.presentHeaders = presentHeaders
        self.userLabelNames = userLabelNames
        self.systemLabelIDs = systemLabelIDs
    }

    public init(message: HeaderMessage, labels: LabelSnapshot) {
        let from = message.first("From").flatMap(Self.sender)
        let subject = Self.normalizeSubject(message.first("Subject") ?? "")
        var senderTokens = from?.name.map { Self.tokens(Self.normalizeText($0)) } ?? []
        if let address = from?.address, let at = address.lastIndex(of: "@") {
            senderTokens += Self.tokens(String(address[..<at]))
        }
        var present: Set<String> = []
        for (name, values) in message.headers
        where values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            present.insert(name.lowercased())
        }
        var userNames: [String] = []
        var system: Set<String> = []
        for id in message.labelIDs.sorted() {
            if let label = labels.label(id: id) {
                if label.kind == .system { system.insert(id) } else { userNames.append(label.name) }
            } else if Self.looksLikeSystemID(id) {
                system.insert(id)
            }
        }
        self.init(fromAddress: from?.address, fromName: from?.name, subject: subject, subjectTokens: Self.tokens(subject),
                  senderTokens: senderTokens, autoSubmitted: message.first("Auto-Submitted").flatMap(Self.normalizeAutoSubmitted),
                  presentHeaders: present, userLabelNames: userNames.sorted(), systemLabelIDs: system)
    }

    /// Whether the decider has `name` with a non-empty trimmed value; names are case-insensitive (design §7.1).
    public func hasHeader(_ name: String) -> Bool {
        presentHeaders.contains(name.lowercased())
    }

    // MARK: - Normalisation

    /// From's first entry that is a valid address once `(comments)` are stripped (fixes
    /// `Virtanen, Matti <m@x.fi>` and `noreply@x.com (No Reply)`). Sender, Reply-To and Return-Path are never used.
    public static func sender(_ header: String) -> (address: String, name: String?)? {
        for entry in AddressParser.parseList(stripComments(header)) {
            let address = entry.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MailAddress(name: nil, email: address).isValid else { continue }
            let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (address, name?.isEmpty == false ? name : nil)
        }
        return nil
    }

    /// Valid addresses of an address-list header (To, Cc), comments stripped, lowercased, `me` removed.
    public static func addresses(_ header: String, excluding me: Set<String> = []) -> [String] {
        AddressParser.parseList(stripComments(header)).compactMap { entry in
            let address = entry.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MailAddress(name: nil, email: address).isValid, !me.contains(address) else { return nil }
            return address
        }
    }

    /// Removes `(…)` comments (nested) outside quoted strings.
    public static func stripComments(_ text: String) -> String {
        var out = ""
        var depth = 0
        var inQuotes = false
        var escaped = false
        for c in text {
            if escaped {
                if depth == 0 { out.append(c) }
                escaped = false
                continue
            }
            switch c {
            case "\\" where inQuotes || depth > 0:
                escaped = true
                if depth == 0 { out.append(c) }
            case "\"" where depth == 0:
                inQuotes.toggle()
                out.append(c)
            case "(" where !inQuotes:
                depth += 1
            case ")" where !inQuotes && depth > 0:
                depth -= 1
                if depth == 0 { out.append(" ") }
            default:
                if depth == 0 { out.append(c) }
            }
        }
        return out
    }

    /// Subject: RFC 2047 decode, at most 1,000 characters, then `normalizeText`.
    public static func normalizeSubject(_ raw: String) -> String {
        normalizeText(String(EncodedWords.decode(raw).prefix(1_000)))
    }

    /// NFC, `\p{Cf}` removed (soft hyphen, zero-width characters, BOM), lowercased.
    public static func normalizeText(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: nfc.unicodeScalars.filter { $0.properties.generalCategory != .format })
        return String(scalars).lowercased()
    }

    /// Maximal runs of `[\p{L}-]+`.
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "-" || isLetter(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                out.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// `Auto-Submitted`: `(comments)` removed, cut at the first `;`, trimmed, lowercased; nil when that leaves nothing.
    public static func normalizeAutoSubmitted(_ raw: String) -> String? {
        let stripped = stripComments(raw)
        let head = stripped.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let value = head.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// Gmail system IDs are upper-case words (`INBOX`, `CATEGORY_PROMOTIONS`); user IDs are `Label_…`.
    static func looksLikeSystemID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { ($0.isASCII && $0.isUppercase) || $0 == "_" || $0.isNumber }
    }
}
