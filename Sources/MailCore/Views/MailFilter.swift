import Foundation

/// One chip in the filter bar. Each filter becomes one Gmail search term; filters combine with AND.
public struct MailFilter: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case from(String)
        /// To or Cc.
        case to(String)
        case subject(String)
        /// Free text anywhere in the message.
        case contains(String)
        case date(DateRange)
        /// nil: any attachment.
        case attachment(AttachmentType?)
        case unread, read, starred, important, calendarInvite
    }

    public enum DateRange: Codable, Hashable, Sendable {
        case lastDays(Int)
        /// Either bound may be open.
        case between(after: Date?, before: Date?)
    }

    public enum AttachmentType: String, Codable, CaseIterable, Sendable {
        case pdf, image, office
    }

    public var id: UUID
    public var kind: Kind
    /// "ei ole": excludes what the filter matches.
    public var negated: Bool

    public init(_ kind: Kind, negated: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.negated = negated
    }

    /// `base` narrowed by `filters`. A base with OR is grouped so the filters apply to all of it.
    public static func query(base: String, _ filters: [MailFilter], calendar: Calendar = .current) -> String {
        let terms = filters.compactMap { $0.term(calendar: calendar) }
        guard !terms.isEmpty else { return base }
        let grouped = base.split(separator: " ").contains("OR") ? "(\(base))" : base
        return ([grouped] + terms).joined(separator: " ")
    }

    /// The Gmail search term, or nil when the filter has no value yet.
    func term(calendar: Calendar) -> String? {
        let minus = negated ? "-" : ""
        switch kind {
        case .from(let v): return Self.value(v).map { "\(minus)from:\($0)" }
        case .to(let v): return Self.value(v).map { "\(minus){to:\($0) cc:\($0)}" }
        case .subject(let v): return Self.value(v).map { "\(minus)subject:\($0)" }
        case .contains(let v): return Self.value(v).map { "\(minus)\($0)" }
        case .unread: return "\(minus)is:unread"
        case .read: return "\(minus)is:read"
        case .starred: return "\(minus)is:starred"
        case .important: return "\(minus)is:important"
        case .calendarInvite: return "\(minus)filename:ics"
        case .attachment(nil): return "\(minus)has:attachment"
        case .attachment(let type?):
            let names = type.extensions.map { "filename:\($0)" }
            return minus + (names.count == 1 ? names[0] : "{\(names.joined(separator: " "))}")
        case .date(.lastDays(let n)):
            return negated ? "older_than:\(n)d" : "newer_than:\(n)d"
        case .date(.between(let after, let before)):
            let day = { (d: Date) in Self.day(d, calendar) }
            if negated {
                // Outside the range: before its start OR after its end.
                let parts = [after.map { "before:\(day($0))" }, before.map { "after:\(day($0))" }].compactMap { $0 }
                guard !parts.isEmpty else { return nil }
                return parts.count == 1 ? parts[0] : "{\(parts.joined(separator: " "))}"
            }
            let parts = [after.map { "after:\(day($0))" }, before.map { "before:\(day($0))" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Trimmed value without quotes, quoted again when it has spaces; nil when empty.
    private static func value(_ raw: String) -> String? {
        let v = raw.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        return v.contains(where: \.isWhitespace) ? "\"\(v)\"" : v
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension MailFilter.AttachmentType {
    var extensions: [String] {
        switch self {
        case .pdf: ["pdf"]
        case .image: ["jpg", "jpeg", "png", "heic", "gif"]
        case .office: ["docx", "doc", "xlsx", "xls", "pptx", "ppt"]
        }
    }
}
