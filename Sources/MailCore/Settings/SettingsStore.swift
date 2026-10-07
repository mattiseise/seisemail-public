import Foundation
import Observation

/// One JSON settings file. `load` returns nil when the file is missing or unreadable.
public struct SettingsFile<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}

/// App and per-account settings. Files are written only when a value changes.
@MainActor @Observable
public final class SettingsStore {
    @ObservationIgnored private let appFile: SettingsFile<AppSettings>
    @ObservationIgnored private let accountFile: @Sendable (String) -> SettingsFile<AccountSettings>

    public var app: AppSettings {
        didSet { if app != oldValue { try? appFile.save(app) } }
    }

    private var accounts: [String: AccountSettings] = [:]

    public init(appFile: SettingsFile<AppSettings>, accountFile: @escaping @Sendable (String) -> SettingsFile<AccountSettings>) {
        self.appFile = appFile
        self.accountFile = accountFile
        self.app = appFile.load() ?? AppSettings()
    }

    /// Production files; `openFirstThread` is carried over from the old UserDefaults key once.
    public static func live(defaults: UserDefaults = .standard) -> SettingsStore {
        let appFile = SettingsFile<AppSettings>(fileURL: AppSettings.defaultURL)
        let isFirstRun = !FileManager.default.fileExists(atPath: appFile.fileURL.path)
        let store = SettingsStore(appFile: appFile, accountFile: { SettingsFile(fileURL: AccountSettings.url(for: $0)) })
        if isFirstRun, defaults.bool(forKey: "openFirstThread") {
            store.app.openFirstThread = true
        }
        return store
    }

    /// Loads accounts' files into memory so views read them without touching disk.
    public func preload(_ emails: [String]) {
        for email in emails.map({ $0.lowercased() }) where accounts[email] == nil {
            accounts[email] = accountFile(email).load() ?? AccountSettings()
        }
    }

    public func account(_ email: String) -> AccountSettings {
        let e = email.lowercased()
        return accounts[e] ?? accountFile(e).load() ?? AccountSettings()
    }

    public func updateAccount(_ email: String, _ body: (inout AccountSettings) -> Void) {
        let e = email.lowercased()
        var value = account(e)
        let old = value
        body(&value)
        accounts[e] = value
        if value != old { try? accountFile(e).save(value) }
    }
}
