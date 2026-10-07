import Foundation

/// Gmail search syntax for label names (conventions §3).
public enum SearchSyntax {
    /// Gmail's search form of a label name: lowercased, "/" and " " → "-".
    /// "Lajittelu/Vaatii toimenpidettä" → "lajittelu-vaatii-toimenpidettä".
    public static func labelToken(_ name: String) -> String {
        String(name.lowercased().map { $0 == "/" || $0 == " " ? "-" : $0 })
    }

    public static func label(_ name: String) -> String {
        "label:" + labelToken(name)
    }

    /// True if a whitespace-separated token, after trimming "(){}" from both ends, equals `term`
    /// case-insensitively and does not start with "-".
    public static func hasPositiveTerm(_ query: String?, _ term: String) -> Bool {
        guard let query else { return false }
        let wanted = term.lowercased()
        return query.split(whereSeparator: \.isWhitespace).contains { raw in
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "(){}"))
            return !token.hasPrefix("-") && token.lowercased() == wanted
        }
    }
}

public struct SortingView: Sendable, Equatable {
    /// "Lajittelu/Kuitit"
    public var labelName: String
    /// The name without `SeiseLabels.Sorting.prefix`: "Kuitit"
    public var title: String
    /// "in:inbox label:lajittelu-kuitit"
    public var query: String

    public init(labelName: String, title: String, query: String) {
        self.labelName = labelName
        self.title = title
        self.query = query
    }
}

/// Inbox-zero queries. Constants only; the views use them in the UI step.
public enum InboxZero {
    public static let excludedFromDefault: [String] = [SeiseLabels.Sorting.newsletters, SeiseLabels.Sorting.notifications]

    /// "in:inbox -label:lajittelu-uutiskirjeet -label:lajittelu-ilmoitukset"
    public static let defaultQuery: String = (["in:inbox"] + excludedFromDefault.map { "-" + SearchSyntax.label($0) })
        .joined(separator: " ")

    /// `query` as sent to Gmail while `missingLabels` do not exist: their `-label:` exclusions are
    /// dropped. Gmail answers a query that excludes a missing label with nothing at all (Matti,
    /// 5.10.2026); without the label no thread can carry it, so dropping the term keeps the meaning.
    /// Positive `label:` terms stay (nothing matches them, which is right).
    public static func serverQuery(_ query: String, missingLabels: Set<String>) -> String {
        guard !missingLabels.isEmpty else { return query }
        let dropped = Set(missingLabels.map { "-" + SearchSyntax.label($0) })
        let terms = query.split(whereSeparator: \.isWhitespace)
        let kept = terms.filter { !dropped.contains($0.lowercased()) }
        return kept.count == terms.count ? query : kept.joined(separator: " ")
    }

    public static func sortingQuery(_ labelName: String) -> String {
        "in:inbox " + SearchSyntax.label(labelName)
    }

    /// In `SeiseLabels.Sorting.all` order.
    public static let sortingViews: [SortingView] = SeiseLabels.Sorting.all.map { name in
        let prefix = SeiseLabels.Sorting.prefix
        let title = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        return SortingView(labelName: name, title: title, query: sortingQuery(name))
    }
}
