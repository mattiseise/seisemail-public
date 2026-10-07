import Foundation

/// One-time move from the single-account layout (token under `google-oauth`, `views.json`)
/// to per-account storage. The account's email comes from the Gmail profile.
public enum AccountMigration {
    /// Returns the account list to use, or nil if migration must be retried later (e.g. offline).
    public static func run(
        legacy: TokenStore,
        tokenStore: @Sendable (String) -> TokenStore,
        accounts: AccountListStore,
        legacyViewsURL: URL,
        viewsURL: @Sendable (String) -> URL,
        fetchEmail: @Sendable (TokenStore) async throws -> String
    ) async -> AccountList? {
        if let existing = accounts.load() { return existing }
        guard let tokens = legacy.load() else { return AccountList() }
        guard let email = try? await fetchEmail(legacy).lowercased() else { return nil }

        tokenStore(email).save(tokens)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyViewsURL.path) {
            let target = viewsURL(email)
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: legacyViewsURL, to: target)
        }
        var list = AccountList()
        list.add(email)
        do {
            try accounts.save(list)
        } catch {
            return nil
        }
        legacy.clear()
        return list
    }
}
