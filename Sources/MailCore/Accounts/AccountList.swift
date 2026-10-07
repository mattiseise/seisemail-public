import Foundation

/// Signed-in accounts in sidebar order, plus the one on screen. Emails are stored lowercased.
public struct AccountList: Codable, Equatable, Sendable {
    public var emails: [String]
    public var active: String?

    public init(emails: [String] = [], active: String? = nil) {
        self.emails = emails.map { $0.lowercased() }
        self.active = active?.lowercased()
    }

    /// Adds and activates the account. Returns false if it already existed (it is still activated).
    @discardableResult
    public mutating func add(_ email: String) -> Bool {
        let e = email.lowercased()
        defer { active = e }
        guard !emails.contains(e) else { return false }
        emails.append(e)
        return true
    }

    public mutating func remove(_ email: String) {
        let e = email.lowercased()
        emails.removeAll { $0 == e }
        if active == e { active = emails.first }
    }

    public mutating func activate(_ email: String) {
        let e = email.lowercased()
        if emails.contains(e) { active = e }
    }
}

public struct AccountListStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL { AppPaths.supportDirectory.appendingPathComponent("accounts.json") }

    public func load() -> AccountList? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AccountList.self, from: data)
    }

    public func save(_ list: AccountList) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: fileURL, options: .atomic)
    }
}
