import Foundation

/// `daemon.json` and `rules.json`, re-read whenever a file changes (its stamp: mtime, size, inode).
/// An invalid file is refused as a whole: the last valid copy, or the defaults, stays in effect and
/// `problems` says why (design §7.2, §10). A missing file means the defaults.
public actor ConfigStore {
    private struct Slot<Value: Sendable>: Sendable {
        var stamp: FileStamp?
        var seen = false
        var value: Value
        var problems: [String] = []
    }

    private let paths: DaemonPaths
    private var config = Slot(value: DaemonConfig())
    private var rules = Slot(value: CompiledRules.defaults)

    public init(paths: DaemonPaths) {
        self.paths = paths
    }

    /// The effective config and rules. Cheap when nothing changed (two `stat`s).
    public func current() -> (config: DaemonConfig, rules: CompiledRules, problems: [String]) {
        reload(&config, url: paths.config, fallback: DaemonConfig()) { data throws(ConfigError) in
            try DaemonConfig.decode(data)
        } problems: { $0.problems }
        reload(&rules, url: paths.rules, fallback: CompiledRules.defaults) { data throws(RuleSetError) in
            try RuleSet.load(data)
        } problems: { $0.problems.map { $0.hasPrefix("rules.json") ? $0 : "rules.json: " + $0 } }
        return (config.value, rules.value, config.problems + rules.problems)
    }

    private func reload<Value: Sendable, E: Error>(
        _ slot: inout Slot<Value>, url: URL, fallback: Value,
        parse: (Data) throws(E) -> Value, problems describe: (E) -> [String]
    ) {
        let stamp = AtomicFile.stamp(url)
        guard !slot.seen || stamp != slot.stamp else { return }
        slot.seen = true
        slot.stamp = stamp
        guard stamp != nil else {
            slot.value = fallback
            slot.problems = []
            return
        }
        do {
            guard let data = try AtomicFile.read(url) else {
                slot.value = fallback
                slot.problems = []
                return
            }
            do {
                slot.value = try parse(data)
                slot.problems = []
            } catch {
                slot.problems = describe(error)   // keep the last good value
            }
        } catch {
            slot.problems = ["\(url.lastPathComponent): ei luettavissa (\(error))"]
        }
    }
}
