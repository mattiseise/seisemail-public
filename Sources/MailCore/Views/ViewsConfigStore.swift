import Foundation

public struct MailView: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var query: String
    /// SF Symbol name shown in the sidebar.
    public var icon: String?
    /// Chips from the filter bar, applied on top of `query`.
    public var filters: [MailFilter]

    public init(id: UUID = UUID(), name: String, query: String, icon: String? = nil, filters: [MailFilter] = []) {
        self.id = id
        self.name = name
        self.query = query
        self.icon = icon
        self.filters = filters
    }

    /// What is sent to Gmail: the view's search narrowed by its filters.
    public var effectiveQuery: String { MailFilter.query(base: query, filters) }

    private enum CodingKeys: String, CodingKey { case id, name, query, icon, filters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        query = try c.decode(String.self, forKey: .query)
        icon = c.lenient(.icon)
        // Views saved before filters existed have none; an unreadable list is dropped, not the view.
        filters = c.lenient(.filters) ?? []
    }

    /// Fixed Gmail folders shown under "Posti"; not user-editable.
    public static let folders: [MailView] = [
        MailView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!, name: "Kaikki", query: "in:anywhere -in:trash -in:spam", icon: "tray.2"),
        MailView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F002")!, name: "Lähetetyt", query: "in:sent", icon: "paperplane"),
        MailView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F003")!, name: "Luonnokset", query: "in:drafts", icon: "doc"),
        MailView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F004")!, name: "Roskaposti", query: "in:spam", icon: "exclamationmark.octagon"),
        MailView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F005")!, name: "Roskakori", query: "in:trash", icon: "trash"),
    ]
}

public enum AppPaths {
    /// `MAK8R_DATA_DIR` (`make screenshots`): the app's files under that folder, never the user's own.
    public static var overrideRoot: URL? {
        ProcessInfo.processInfo.environment["MAK8R_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static var supportDirectory: URL {
        overrideRoot?.appendingPathComponent("support", isDirectory: true)
            ?? URL.applicationSupportDirectory.appendingPathComponent("Mak8rMail", isDirectory: true)
    }

    public static var cacheDirectory: URL {
        overrideRoot?.appendingPathComponent("cache", isDirectory: true)
            ?? URL.cachesDirectory.appendingPathComponent("Mak8rMail", isDirectory: true)
    }

    /// `~/Library/Logs/Mak8rMail` (the daemon's logs).
    public static var logsDirectory: URL {
        URL.libraryDirectory.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Mak8rMail", isDirectory: true)
    }
}

public struct ViewsConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL { AppPaths.supportDirectory.appendingPathComponent("views.json") }

    public static func url(for email: String) -> URL {
        AppPaths.supportDirectory.appendingPathComponent("views-\(email.lowercased()).json")
    }

    public static var defaults: [MailView] {
        [
            MailView(name: "Inbox", query: "in:inbox", icon: "tray"),
            MailView(name: "Tärkeät", query: "in:inbox is:important -category:promotions -category:social", icon: "exclamationmark.circle"),
            MailView(name: "Uutiskirjeet", query: "category:promotions OR category:updates", icon: "newspaper"),
            MailView(name: "Tähdellä", query: "is:starred", icon: "star"),
        ]
    }

    /// The first release's defaults; Sent and All Mail have since moved to the fixed folders.
    private static let firstDefaults: [(String, String)] = [
        ("Inbox", "in:inbox"),
        ("Tärkeät", "in:inbox is:important -category:promotions -category:social"),
        ("Uutiskirjeet", "category:promotions OR category:updates"),
        ("Tähdellä", "is:starred"),
        ("Lähetetyt", "in:sent"),
        ("Kaikki", "in:anywhere -in:trash -in:spam"),
    ]

    private static func migrated(_ views: [MailView]) -> [MailView]? {
        guard views.map({ [$0.name, $0.query] }) == firstDefaults.map({ [$0.0, $0.1] }) else { return nil }
        return zip(views.prefix(4), defaults).map { old, new in
            MailView(id: old.id, name: old.name, query: old.query, icon: new.icon)
        }
    }

    public func load() -> [MailView] {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: fileURL) {
            if let views = try? JSONDecoder().decode([MailView].self, from: data) {
                if let upgraded = Self.migrated(views) {
                    try? save(upgraded)
                    return upgraded
                }
                return views
            }
            let backup = fileURL.appendingPathExtension("broken")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: fileURL, to: backup)
        }
        let views = Self.defaults
        try? save(views)
        return views
    }

    public func save(_ views: [MailView]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(views).write(to: fileURL, options: .atomic)
    }
}
