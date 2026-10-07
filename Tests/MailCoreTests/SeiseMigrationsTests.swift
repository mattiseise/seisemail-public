import Foundation
import Testing
@testable import MailCore

/// The fork's one-time migrations: the `h` shortcut and the Käsiteltävät/Torkku views.
@MainActor
@Suite struct SeiseMigrationsTests {
    let dir = makeTempDir()
    nonisolated static let inboxZeroID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
    nonisolated static let snoozedID = UUID(uuidString: "00000000-0000-0000-0000-00000000E002")!
    nonisolated static let forkNames = ["Käsiteltävät", "Inbox", "Tärkeät", "Uutiskirjeet", "Tähdellä", "Torkku"]

    /// The upstream 15-key map, as every settings.json written before Phase 1 holds it.
    nonisolated static let oldMap: [String: MailCommand] = [
        "j": .next, "k": .previous, "o": .open, "u": .back,
        "e": .archive, "s": .star, "#": .trash, "U": .markUnread,
        "r": .reply, "a": .replyAll, "f": .forward, "c": .compose, "/": .search,
        "x": .toggleCheck, "I": .markRead,
    ]

    var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    var stateURL: URL { dir.appendingPathComponent("seise-migrations.json") }

    func settingsStore() -> SettingsStore {
        let dir = self.dir
        return SettingsStore(appFile: SettingsFile(fileURL: dir.appendingPathComponent("settings.json")),
                             accountFile: { SettingsFile(fileURL: dir.appendingPathComponent("settings-\($0).json")) })
    }

    func migrations() -> SeiseMigrations {
        SeiseMigrations(stateFile: SettingsFile(fileURL: stateURL))
    }

    func writeSettings(shortcuts: [String: MailCommand]) throws {
        var settings = AppSettings()
        settings.shortcuts = shortcuts
        try SettingsFile<AppSettings>(fileURL: settingsURL).save(settings)
    }

    func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    func viewsStore(_ name: String = "views.json") -> ViewsConfigStore {
        ViewsConfigStore(fileURL: dir.appendingPathComponent(name))
    }

    // MARK: - ShortcutMigration (pure)

    @Test func shortcutAddsHToOldMap() throws {
        #expect(Self.oldMap.count == 15)
        let result = try #require(ShortcutMigration.addingSnooze(to: Self.oldMap))
        var expected = Self.oldMap
        expected["h"] = .snooze
        #expect(result == expected)
        #expect(result.count == 16)
    }

    @Test func shortcutKeepsCustomKeys() {
        var custom = Self.oldMap
        custom["e"] = nil
        custom["y"] = .archive
        var expected = custom
        expected["h"] = .snooze
        #expect(ShortcutMigration.addingSnooze(to: custom) == expected)
        #expect(ShortcutMigration.addingSnooze(to: [:]) == ["h": .snooze])
    }

    @Test func shortcutHTaken() {
        #expect(ShortcutMigration.addingSnooze(to: ["h": .archive, "j": .next]) == nil)
        var taken = Self.oldMap
        taken["h"] = .reply
        #expect(ShortcutMigration.addingSnooze(to: taken) == nil)
    }

    @Test func shortcutBoundElsewhere() {
        #expect(ShortcutMigration.addingSnooze(to: ["z": .snooze]) == nil)
        var bound = Self.oldMap
        bound["z"] = .snooze
        #expect(ShortcutMigration.addingSnooze(to: bound) == nil)
    }

    @Test func shortcutDefaultsUnchanged() {
        #expect(ShortcutMap.defaults == Self.oldMap.merging(["h": .snooze]) { a, _ in a })
        #expect(ShortcutMigration.addingSnooze(to: ShortcutMap.defaults) == nil)
        #expect(ShortcutMigration.key == "shortcuts.snooze-h")
    }

    // MARK: - SeiseMigrations.migrateShortcuts

    @Test func runnerWritesOnce() throws {
        try writeSettings(shortcuts: Self.oldMap)
        let settings = settingsStore()
        let runner = migrations()
        runner.migrateShortcuts(settings)
        var expected = Self.oldMap
        expected["h"] = .snooze
        #expect(settings.app.shortcuts == expected)
        #expect(SettingsFile<AppSettings>(fileURL: settingsURL).load()?.shortcuts == expected)
        #expect(runner.state.applied.contains(ShortcutMigration.key))
        let written = try bytes(settingsURL)

        runner.migrateShortcuts(settings)                                    // same run, again
        #expect(try bytes(settingsURL) == written)
        let nextLaunch = settingsStore()
        migrations().migrateShortcuts(nextLaunch)                            // next launch
        #expect(try bytes(settingsURL) == written)
        #expect(nextLaunch.app.shortcuts == expected)
    }

    @Test func runnerNoSettingsFile() {
        let settings = settingsStore()
        let runner = migrations()
        runner.migrateShortcuts(settings)
        #expect(!FileManager.default.fileExists(atPath: settingsURL.path))
        #expect(settings.app.shortcuts == ShortcutMap.defaults)
        #expect(runner.state.applied.contains(ShortcutMigration.key))
        #expect(migrations().state.applied.contains(ShortcutMigration.key))  // persisted
    }

    @Test func runnerBrokenSettingsUntouched() throws {
        try Data("{ not json".utf8).write(to: settingsURL)
        let settings = settingsStore()
        migrations().migrateShortcuts(settings)
        #expect(try bytes(settingsURL) == Data("{ not json".utf8))
    }

    @Test func runnerOnce() throws {
        try writeSettings(shortcuts: Self.oldMap)
        let settings = settingsStore()
        migrations().migrateShortcuts(settings)
        #expect(settings.app.shortcuts["h"] == .snooze)
        settings.app.shortcuts = Self.oldMap                                 // Matti unbinds snooze later
        let unbound = try bytes(settingsURL)
        let relaunched = settingsStore()
        migrations().migrateShortcuts(relaunched)                            // applied, snooze unbound, h free
        #expect(relaunched.app.shortcuts == Self.oldMap)
        #expect(try bytes(settingsURL) == unbound)
    }

    @Test func runnerNeverTakesAKey() throws {
        var custom = Self.oldMap
        custom["h"] = .archive
        try writeSettings(shortcuts: custom)
        let before = try bytes(settingsURL)
        let settings = settingsStore()
        migrations().migrateShortcuts(settings)
        #expect(settings.app.shortcuts == custom)
        #expect(try bytes(settingsURL) == before)
    }

    // MARK: - SeiseViews (pure)

    @Test func viewsQueriesAreContract() {
        #expect(SeiseViews.inboxZeroID == Self.inboxZeroID)
        #expect(SeiseViews.snoozedID == Self.snoozedID)
        let zero = SeiseViews.inboxZero
        #expect(zero.id == Self.inboxZeroID)
        #expect(zero.name == "Käsiteltävät")
        #expect(zero.query == InboxZero.defaultQuery)
        #expect(zero.query == "in:inbox -label:lajittelu-uutiskirjeet -label:lajittelu-ilmoitukset")
        #expect(zero.icon == "tray.full")
        #expect(zero.filters.isEmpty)
        let snoozed = SeiseViews.snoozed
        #expect(snoozed.id == Self.snoozedID)
        #expect(snoozed.name == "Torkku")
        #expect(snoozed.query == "label:torkku")
        #expect(snoozed.query == SnoozeLabelScheme.standard.viewQuery)
        #expect(snoozed.icon == "moon.zzz")
        #expect(snoozed.filters.isEmpty)
    }

    @Test func viewsFromDefaults() throws {
        let upstream = ViewsConfigStore.defaults
        let result = try #require(SeiseViews.adding(to: upstream))
        #expect(result.map(\.name) == Self.forkNames)
        #expect(Array(result[1...4]) == upstream)                            // upstream views untouched, IDs kept
        #expect(result.first?.id == Self.inboxZeroID)
        #expect(result.last?.id == Self.snoozedID)
    }

    @Test func viewsCustomOrderKept() throws {
        let a = MailView(name: "A", query: "label:a", icon: "star")
        let b = MailView(name: "B", query: "from:b@example.fi", filters: [MailFilter(.unread)])
        let result = try #require(SeiseViews.adding(to: [a, b]))
        #expect(result == [SeiseViews.inboxZero, a, b, SeiseViews.snoozed])
    }

    @Test func viewsEquivalentNotDuplicated() {
        let views = [
            MailView(name: "Oma nolla", query: "in:inbox  -label:lajittelu-uutiskirjeet   -label:lajittelu-ilmoitukset"),
            MailView(name: "Inbox", query: "in:inbox"),
            MailView(name: "Torkut", query: "LABEL:Torkku"),
        ]
        #expect(SeiseViews.adding(to: views) == nil)
    }

    @Test func viewsAddsOnlyMissing() throws {
        let inbox = MailView(name: "Inbox", query: "in:inbox")
        let torkku = MailView(name: "Torkut", query: "Label:torkku")
        let result = try #require(SeiseViews.adding(to: [inbox, torkku]))
        #expect(result == [SeiseViews.inboxZero, inbox, torkku])
        let zero = MailView(name: "Nolla", query: InboxZero.defaultQuery.uppercased())
        let second = try #require(SeiseViews.adding(to: [zero, inbox]))
        #expect(second == [zero, inbox, SeiseViews.snoozed])
    }

    @Test func viewsMatchedByID() throws {
        let renamed = MailView(id: Self.snoozedID, name: "Herätettävät", query: "label:torkku is:unread")
        let result = try #require(SeiseViews.adding(to: [renamed]))
        #expect(result == [SeiseViews.inboxZero, renamed])                   // never renamed or replaced
        let both = [MailView(id: Self.inboxZeroID, name: "Nolla", query: "in:inbox"), renamed]
        #expect(SeiseViews.adding(to: both) == nil)
    }

    // MARK: - SeiseViews.kind (owner decision 3, 2026-10-04)

    @Test func kindByID() {
        #expect(SeiseViews.kind(of: SeiseViews.inboxZero) == .inboxZero)
        #expect(SeiseViews.kind(of: SeiseViews.snoozed) == .snoozed)
        // The fixed ID wins even after Matti edits the query (Q9: "in:inbox").
        #expect(SeiseViews.kind(of: MailView(id: Self.inboxZeroID, name: "Nolla", query: "in:inbox")) == .inboxZero)
        #expect(SeiseViews.kind(of: MailView(id: Self.snoozedID, name: "T", query: "label:torkku is:unread")) == .snoozed)
        #expect(SeiseViews.kind(of: MailView(id: Self.snoozedID, name: "T", query: InboxZero.defaultQuery)) == .snoozed)
    }

    @Test func kindByEquivalentQuery() {
        #expect(SeiseViews.kind(of: MailView(name: "Oma nolla", query: InboxZero.defaultQuery)) == .inboxZero)
        #expect(SeiseViews.kind(of: MailView(name: "Torkut", query: "label:torkku")) == .snoozed)
    }

    @Test func kindQueryDiffersOnlyByNormalisation() {
        let zero = MailView(name: "N", query: "  IN:inbox  -label:Lajittelu-uutiskirjeet\t-label:lajittelu-ilmoitukset ")
        #expect(SeiseViews.kind(of: zero) == .inboxZero)
        #expect(SeiseViews.kind(of: MailView(name: "T", query: "LABEL:Torkku")) == .snoozed)
        #expect(SeiseViews.kind(of: MailView(name: "T", query: " label:torkku\n")) == .snoozed)
    }

    @Test func kindNonEquivalentIsOther() {
        #expect(SeiseViews.kind(of: MailView(name: "Inbox", query: "in:inbox")) == .other)
        #expect(SeiseViews.kind(of: MailView(name: "N", query: "in:inbox -label:lajittelu-uutiskirjeet")) == .other)
        #expect(SeiseViews.kind(of: MailView(name: "T", query: "label:torkku is:unread")) == .other)
        #expect(SeiseViews.kind(of: MailView(name: "T", query: "label:torkku/20261005T0500Z")) == .other)
        #expect(SeiseViews.kind(of: MailView(name: "T", query: "label:tor kku")) == .other)
        // Supersets of the inbox-zero query (prefix match would accept them) are not equivalent.
        #expect(SeiseViews.kind(of: MailView(name: "N", query: InboxZero.defaultQuery + " is:unread")) == .other)
        #expect(SeiseViews.kind(of: MailView(name: "N", query: InboxZero.defaultQuery + " from:boss")) == .other)
        #expect(SeiseViews.kind(of: MailView(name: "N", query: "x " + InboxZero.defaultQuery)) == .other)
        // Equivalence is order-sensitive: reordered terms are a different query.
        let terms = InboxZero.defaultQuery.split(separator: " ")
        let reordered = (terms.dropFirst() + terms.prefix(1)).joined(separator: " ")
        #expect(reordered != InboxZero.defaultQuery)
        #expect(SeiseViews.kind(of: MailView(name: "N", query: reordered)) == .other)
        // Equivalence is the query's, so the same rule as SeiseViews.adding: a view it would not add again.
        for view in ViewsConfigStore.defaults { #expect(SeiseViews.kind(of: view) == .other) }
    }

    @Test func defaultsMatchMigration() throws {
        let migrated = try #require(SeiseViews.adding(to: ViewsConfigStore.defaults))
        #expect(SeiseViews.defaults.map(\.name) == migrated.map(\.name))
        #expect(SeiseViews.defaults.map(\.query) == migrated.map(\.query))
        #expect(SeiseViews.defaults.map(\.icon) == migrated.map(\.icon))
        #expect(SeiseViews.defaults.first == SeiseViews.inboxZero)
        #expect(SeiseViews.defaults.last == SeiseViews.snoozed)
        #expect(SeiseViews.adding(to: SeiseViews.defaults) == nil)
    }

    // MARK: - SeiseMigrations.migrateViews

    @Test func viewsKeyIsLowercased() {
        #expect(SeiseMigrations.viewsKey("Maija@Example.FI") == "views.v1:maija@example.fi")
    }

    @Test func viewsMissingFile() {
        let store = viewsStore()
        let runner = migrations()
        runner.migrateViews(email: "m@x.fi", store: store)
        let views = store.load()
        #expect(views.count == 6)
        #expect(views.map(\.name) == Self.forkNames)
        #expect(views.first?.id == Self.inboxZeroID)
        #expect(views.last?.id == Self.snoozedID)
        #expect(runner.state.applied.contains(SeiseMigrations.viewsKey("m@x.fi")))
        #expect(migrations().state.applied.contains("views.v1:m@x.fi"))
    }

    @Test func viewsFirstReleaseFile() throws {
        let store = viewsStore()
        let old = [
            ("Inbox", "in:inbox"),
            ("Tärkeät", "in:inbox is:important -category:promotions -category:social"),
            ("Uutiskirjeet", "category:promotions OR category:updates"),
            ("Tähdellä", "is:starred"),
            ("Lähetetyt", "in:sent"),
            ("Kaikki", "in:anywhere -in:trash -in:spam"),
        ].map { ["id": UUID().uuidString, "name": $0.0, "query": $0.1] }
        try JSONSerialization.data(withJSONObject: old).write(to: store.fileURL)
        migrations().migrateViews(email: "m@x.fi", store: store)
        let views = store.load()
        #expect(views.map(\.name) == Self.forkNames)
        #expect(views[1...4].map(\.id.uuidString) == old.prefix(4).map { $0["id"]! })
        #expect(views[1].icon == "tray")                                     // upstream migration ran too
    }

    @Test func viewsBrokenFile() throws {
        let store = viewsStore()
        try Data("{ not json".utf8).write(to: store.fileURL)
        migrations().migrateViews(email: "m@x.fi", store: store)
        let backup = dir.appendingPathComponent("views.json.broken")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
        #expect(store.load().map(\.name) == Self.forkNames)
    }

    @Test func viewsCustomFileGainsBoth() throws {
        let store = viewsStore()
        let work = MailView(name: "Työ", query: "label:work")
        try store.save([work])
        migrations().migrateViews(email: "m@x.fi", store: store)
        #expect(store.load() == [SeiseViews.inboxZero, work, SeiseViews.snoozed])
    }

    @Test func viewsAlreadyPresentMarksApplied() throws {
        let store = viewsStore()
        try store.save(SeiseViews.defaults)
        let before = try bytes(store.fileURL)
        let runner = migrations()
        runner.migrateViews(email: "m@x.fi", store: store)
        #expect(try bytes(store.fileURL) == before)
        #expect(runner.state.applied.contains("views.v1:m@x.fi"))
    }

    @Test func viewsDeletedStayDeleted() throws {
        let store = viewsStore()
        migrations().migrateViews(email: "m@x.fi", store: store)
        let withoutTorkku = store.load().filter { $0.id != Self.snoozedID }
        try store.save(withoutTorkku)
        let before = try bytes(store.fileURL)
        migrations().migrateViews(email: "m@x.fi", store: store)
        #expect(store.load() == withoutTorkku)
        #expect(try bytes(store.fileURL) == before)
    }

    @Test func viewsSaveFailureMarksNothing() throws {
        let blocker = dir.appendingPathComponent("blocker")
        try Data("file".utf8).write(to: blocker)                             // the views path's parent is a file
        let store = ViewsConfigStore(fileURL: blocker.appendingPathComponent("views.json"))
        let runner = migrations()
        runner.migrateViews(email: "m@x.fi", store: store)
        #expect(!runner.state.applied.contains("views.v1:m@x.fi"))
        #expect(!migrations().state.applied.contains("views.v1:m@x.fi"))
    }

    @Test func viewsPerAccountLowercased() throws {
        let first = viewsStore("views-m.json")
        migrations().migrateViews(email: "M@X", store: first)
        #expect(first.load().map(\.name) == Self.forkNames)
        let only = [MailView(name: "A", query: "label:a")]
        try first.save(only)
        migrations().migrateViews(email: "m@x", store: first)                // same account: no-op
        #expect(first.load() == only)
        let other = viewsStore("views-b.json")
        migrations().migrateViews(email: "b@x", store: other)                // another account migrates
        #expect(other.load().map(\.name) == Self.forkNames)
        let state = migrations().state.applied
        #expect(state.contains("views.v1:m@x"))
        #expect(state.contains("views.v1:b@x"))
        #expect(!state.contains("views.v1:M@X"))
    }

    @Test func shortcutsAndViewsShareOneStateFile() {
        let runner = migrations()
        runner.migrateShortcuts(settingsStore())
        runner.migrateViews(email: "m@x.fi", store: viewsStore())
        #expect(migrations().state.applied == [ShortcutMigration.key, "views.v1:m@x.fi"])
    }

    // MARK: - State file

    @Test func lenientState() throws {
        try Data("{ not json".utf8).write(to: stateURL)
        #expect(migrations().state.applied.isEmpty)
        let wrongType = try JSONDecoder().decode(SeiseMigrationState.self, from: Data(#"{"applied": 5}"#.utf8))
        #expect(wrongType.applied.isEmpty)
        let valid = try JSONDecoder().decode(SeiseMigrationState.self, from: Data(#"{"applied": ["x"]}"#.utf8))
        #expect(valid.applied == ["x"])
        #expect(SeiseMigrationState().applied.isEmpty)
    }

    @Test func stateDefaultURL() {
        #expect(SeiseMigrationState.defaultURL.lastPathComponent == "seise-migrations.json")
        #expect(SeiseMigrationState.defaultURL.deletingLastPathComponent().standardizedFileURL
                == AppPaths.supportDirectory.standardizedFileURL)
    }
}
