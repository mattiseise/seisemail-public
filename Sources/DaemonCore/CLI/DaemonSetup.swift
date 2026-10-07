import Darwin
import Foundation

/// `init` and `mode` (design §15). Both write only Matti's files in the support folder, atomically:
/// `rules.json` 0644, `daemon.json` 0600 (§9.1: it holds the notify hook's argv, so it is the owner's only).
public enum DaemonSetup {
    /// `daemon.json`'s mode: 0600 for a new file. An existing file keeps at most its owner bits, so a
    /// rewrite never makes it more permissive than Matti left it (0644 → 0600, 0400 stays 0400).
    public static func configMode(existing: mode_t?) -> mode_t {
        guard let existing else { return 0o600 }
        return existing & 0o600
    }

    /// Every writer of `daemon.json` goes through here (atomic, `configMode`).
    public static func writeConfig(_ config: DaemonConfig, to url: URL) throws {
        try AtomicFile.write(config.encoded(), to: url, mode: configMode(existing: AtomicFile.mode(url)))
    }

    /// Creates the folders (0700) and writes `daemon.json` (defaults) and `rules.json` (§7.3 defaults)
    /// only when missing. Returns the files it created. `make daemon-install` runs this. An existing
    /// `daemon.json` is left as it is, except that group and other bits are dropped (an install made before
    /// the 0600 rule is repaired; nothing is ever widened).
    @discardableResult
    public static func initialize(paths: DaemonPaths) throws -> [URL] {
        try paths.createDirectories()
        var created: [URL] = []
        if let existing = AtomicFile.mode(paths.config) {
            let narrowed = configMode(existing: existing)
            if narrowed != existing, chmod(paths.config.path, narrowed) != 0 { throw FileError("chmod", paths.config.path) }
        } else {
            try writeConfig(DaemonConfig(), to: paths.config)
            created.append(paths.config)
        }
        if AtomicFile.stamp(paths.rules) == nil {
            try AtomicFile.write(Data(DefaultRules.json.utf8), to: paths.rules, mode: 0o644)
            created.append(paths.rules)
        }
        return created
    }

    /// Sets one feature's mode in `daemon.json`, keeping every other field. A missing file starts from
    /// the defaults; an invalid one is refused untouched (Matti fixes it first). The daemon reads the
    /// change on its next tick.
    @discardableResult
    public static func setMode(_ feature: DaemonCommand.Feature, _ mode: FeatureMode,
                               paths: DaemonPaths) throws(ConfigError) -> DaemonConfig {
        var config = DaemonConfig()
        do {
            if let data = try AtomicFile.read(paths.config) {
                config = try DaemonConfig.decode(data)
            }
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError(problems: ["daemon.json: ei luettavissa (\(error))"])
        }
        switch feature {
        case .wake: config.wake = mode
        case .sorting: config.sorting = mode
        }
        do {
            try AtomicFile.ensureDirectory(paths.support, mode: 0o755, tighten: false)
            try writeConfig(config, to: paths.config)
        } catch {
            throw ConfigError(problems: ["daemon.json: kirjoitus epäonnistui (\(error))"])
        }
        return config
    }
}
