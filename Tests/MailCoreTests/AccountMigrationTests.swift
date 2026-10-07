import Foundation
import Synchronization
import Testing
@testable import MailCore

@Suite struct AccountMigrationTests {
    let dir = makeTempDir()
    let token = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0))

    final class Stores: Sendable {
        let map = Mutex<[String: MemoryTokenStore]>([:])
        func store(_ email: String) -> TokenStore {
            map.withLock { m in
                if let s = m[email] { return s }
                let s = MemoryTokenStore(); m[email] = s; return s
            }
        }
    }

    func run(legacy: MemoryTokenStore, stores: Stores, fetch: @escaping @Sendable (TokenStore) async throws -> String) async -> AccountList? {
        let dir = self.dir
        return await AccountMigration.run(
            legacy: legacy,
            tokenStore: { stores.store($0) },
            accounts: AccountListStore(fileURL: dir.appendingPathComponent("accounts.json")),
            legacyViewsURL: dir.appendingPathComponent("views.json"),
            viewsURL: { dir.appendingPathComponent("views-\($0).json") },
            fetchEmail: fetch
        )
    }

    @Test func movesLegacyTokenAndViewsToFirstAccount() async throws {
        let legacy = MemoryTokenStore(token)
        let stores = Stores()
        try Data("[]".utf8).write(to: dir.appendingPathComponent("views.json"))
        let list = await run(legacy: legacy, stores: stores) { store in
            #expect(store.load() == TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0)))
            return "Maija@Example.fi"
        }
        #expect(list == AccountList(emails: ["maija@example.fi"], active: "maija@example.fi"))
        #expect(stores.store("maija@example.fi").load() == token)
        #expect(legacy.load() == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("views-maija@example.fi.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("views.json").path))
        #expect(AccountListStore(fileURL: dir.appendingPathComponent("accounts.json")).load() == list)
    }

    @Test func existingAccountListIsReturnedUntouched() async throws {
        let saved = AccountList(emails: ["b@x.fi"], active: "b@x.fi")
        try AccountListStore(fileURL: dir.appendingPathComponent("accounts.json")).save(saved)
        let legacy = MemoryTokenStore(token)
        let calls = Counter()
        let list = await run(legacy: legacy, stores: Stores()) { _ in calls.increment(); return "x@x.fi" }
        #expect(list == saved)
        #expect(calls.count == 0)
        #expect(legacy.load() == token)
    }

    @Test func noLegacyTokenGivesEmptyList() async {
        let list = await run(legacy: MemoryTokenStore(), stores: Stores()) { _ in "x@x.fi" }
        #expect(list == AccountList())
    }

    @Test func failedProfileLookupChangesNothing() async {
        let legacy = MemoryTokenStore(token)
        let list = await run(legacy: legacy, stores: Stores()) { _ in throw GmailError.offline }
        #expect(list == nil)
        #expect(legacy.load() == token)
        #expect(AccountListStore(fileURL: dir.appendingPathComponent("accounts.json")).load() == nil)
    }
}
