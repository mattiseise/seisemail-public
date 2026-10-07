import Foundation

/// Device-local bookkeeping (supportDirectory/seise-migrations.json); never synced (conventions §0).
public struct SeiseMigrationState: Codable, Sendable, Equatable {
    public var applied: Set<String> = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case applied }

    /// Unreadable → empty (the migrations are idempotent).
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        applied = c.lenient(.applied) ?? []
    }

    public static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("seise-migrations.json")
    }
}

/// Phase 1 design D5: `h` for snooze in settings files written before the command existed.
public enum ShortcutMigration {
    public static let key = "shortcuts.snooze-h"

    /// nil = no change. Binds "h" only if no key runs .snooze and "h" is unbound; never takes a key.
    public static func addingSnooze(to keys: [String: MailCommand]) -> [String: MailCommand]? {
        guard !keys.values.contains(.snooze), keys["h"] == nil else { return nil }
        var next = keys
        next["h"] = .snooze
        return next
    }
}

/// One-time fork migrations, each recorded in the state file so a later user change is never undone.
@MainActor
public final class SeiseMigrations {
    public private(set) var state: SeiseMigrationState
    private let stateFile: SettingsFile<SeiseMigrationState>

    public init(stateFile: SettingsFile<SeiseMigrationState>) {
        self.stateFile = stateFile
        self.state = stateFile.load() ?? SeiseMigrationState()
    }

    /// "views.v1:" + lowercased email
    public nonisolated static func viewsKey(_ email: String) -> String {
        "views.v1:" + email.lowercased()
    }

    /// Once per device. Assigns settings.app.shortcuts only on change (SettingsStore saves on change, :31-33).
    public func migrateShortcuts(_ settings: SettingsStore) {
        guard !state.applied.contains(ShortcutMigration.key) else { return }
        if let keys = ShortcutMigration.addingSnooze(to: settings.app.shortcuts) {
            settings.app.shortcuts = keys
        }
        markApplied(ShortcutMigration.key)
    }

    /// Once per account; before AccountSession exists (MailStore.init reads the views file once, MailStore.swift:70).
    /// load() (writes upstream defaults if missing, migrates first-release files) → adding → save if changed →
    /// mark applied. A failed save marks nothing (retried next launch).
    public func migrateViews(email: String, store: ViewsConfigStore) {
        let key = Self.viewsKey(email)
        guard !state.applied.contains(key) else { return }
        if let views = SeiseViews.adding(to: store.load()) {
            do {
                try store.save(views)
            } catch {
                return
            }
        }
        markApplied(key)
    }

    private func markApplied(_ key: String) {
        state.applied.insert(key)
        try? stateFile.save(state)
    }
}
