import Darwin
import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "fi.mak8r.mail", category: "daemon")

public enum StateLoadResult: Sendable, Equatable {
    case loaded(AccountState)
    /// The current file was missing or undecodable; `.bak` was good.
    case recovered(AccountState)
    /// Nothing usable (first run, or both files quarantined): bootstrap (design §6.2).
    case missing
    /// Written by a newer daemon: the account stays untouched (`stateError`).
    case futureSchema(Int)
}

/// Durable per-account state (design §9.3). Writes are atomic with a `.bak` of the previous version;
/// load order is current → `.bak` → bootstrap, and an undecodable file is kept as `*.corrupt-<stamp>`.
/// Watermark-only changes are written at most every `watermarkDebounce` (10 min): the `historyId` moves
/// on every read/unread toggle, and a lost update costs only idempotent replay.
public final class StateStore: Sendable {
    private struct Memo {
        var lastWritten: AccountState?
        var lastWriteAt: Date?
        var lastSaveFailed = false
        var quarantined: [URL] = []
    }

    public let url: URL
    public var backupURL: URL { URL(fileURLWithPath: url.path + ".bak") }
    private let now: @Sendable () -> Date
    private let watermarkDebounce: TimeInterval
    private let memo = Mutex(Memo())

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }, watermarkDebounce: TimeInterval = 600) {
        self.url = url
        self.now = now
        self.watermarkDebounce = watermarkDebounce
    }

    /// True after a failed `save` until one succeeds. While set, the sorter makes no writes (design §10).
    public var lastSaveFailed: Bool { memo.withLock { $0.lastSaveFailed } }

    /// Files the last `load` moved aside as `*.corrupt-<stamp>`.
    public var quarantined: [URL] { memo.withLock { $0.quarantined } }

    public func load() -> StateLoadResult {
        memo.withLock { $0.quarantined = [] }
        switch Self.decode(at: url) {
        case .ok(let state):
            remember(state)
            return .loaded(state)
        case .future(let schema):
            return .futureSchema(schema)
        case .missing:
            break
        case .corrupt:
            quarantine(url)
        }
        switch Self.decode(at: backupURL) {
        case .ok(let state):
            log.notice("state recovered from .bak")
            remember(state)
            return .recovered(state)
        case .future(let schema):
            return .futureSchema(schema)
        case .missing:
            return .missing
        case .corrupt:
            quarantine(backupURL)
            return .missing
        }
    }

    /// Writes `state` if it differs from the last write: at once for anything but the watermark, or when
    /// `force` (shutdown, checkpoints that must be durable); watermark-only changes after the debounce.
    /// Returns whether it wrote. Throws (and sets `lastSaveFailed`) when the write fails.
    @discardableResult
    public func save(_ state: AccountState, force: Bool = false) throws -> Bool {
        let at = now()
        let skip = memo.withLock { m -> Bool in
            guard !m.lastSaveFailed, let last = m.lastWritten else { return false }
            var a = state
            a.writtenAt = last.writtenAt
            if a == last { return true }
            return !force && state.differsOnlyInWatermark(from: last)
                && m.lastWriteAt.map { at.timeIntervalSince($0) < watermarkDebounce } == true
        }
        if skip { return false }
        var stamped = state
        stamped.writtenAt = at
        do {
            try AtomicFile.ensureDirectory(url.deletingLastPathComponent(), mode: 0o700)
            try AtomicFile.write(try DaemonJSON.encoder().encode(stamped), to: url, mode: 0o600, keepBackup: true)
        } catch {
            memo.withLock { $0.lastSaveFailed = true }
            log.error("state write failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        memo.withLock { m in
            m.lastWritten = stamped
            m.lastWriteAt = at
            m.lastSaveFailed = false
        }
        return true
    }

    /// Whether `state` has changes not yet on disk (including a debounced watermark).
    public func isDirty(_ state: AccountState) -> Bool {
        memo.withLock { m in
            guard let last = m.lastWritten else { return true }
            var a = state
            a.writtenAt = last.writtenAt
            return a != last
        }
    }

    private func remember(_ state: AccountState) {
        memo.withLock { m in
            m.lastWritten = state
            m.lastWriteAt = state.writtenAt
        }
    }

    private func quarantine(_ file: URL) {
        let target = URL(fileURLWithPath: file.path + ".corrupt-" + DaemonPaths.stamp(now()))
        if rename(file.path, target.path) == 0 {
            log.error("undecodable state kept as \(target.lastPathComponent, privacy: .public)")
            memo.withLock { $0.quarantined.append(target) }
        }
    }

    /// The state as the CLI may read it while the daemon owns the file (`explain`): the current file, else
    /// `.bak`; nil when neither decodes. Never quarantines, writes or remembers anything.
    public static func peek(_ url: URL) -> AccountState? {
        if case .ok(let state) = decode(at: url) { return state }
        if case .ok(let state) = decode(at: URL(fileURLWithPath: url.path + ".bak")) { return state }
        return nil
    }

    private enum Decoded {
        case ok(AccountState), missing, corrupt, future(Int)
    }

    private struct SchemaProbe: Decodable {
        var schema: Int
    }

    private static func decode(at url: URL) -> Decoded {
        guard let data = try? AtomicFile.read(url) else {
            return access(url.path, F_OK) == 0 ? .corrupt : .missing
        }
        guard let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data) else { return .corrupt }
        if probe.schema > AccountState.currentSchema { return .future(probe.schema) }
        guard probe.schema == AccountState.currentSchema,
              let state = try? DaemonJSON.decoder().decode(AccountState.self, from: data) else { return .corrupt }
        return .ok(state)
    }
}
