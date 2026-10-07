import Foundation
import os

private let log = Logger(subsystem: "fi.mak8r.mail", category: "labels")

public enum LabelDirectoryError: Error, Equatable, Sendable {
    /// Create answered 409/400 and a re-list still has no case-insensitive match (reserved or invalid name).
    case createRejected(name: String, status: Int)
}

/// Per-account name→ID cache (conventions §0). Shared by SnoozeService, SnoozeWaker and later the sorting rules.
public actor LabelDirectory {
    private let api: any GmailLabelsAPI
    private var current: LabelSnapshot?
    private var loading: Task<LabelSnapshot, any Error>?
    /// Keyed by lowercased name, like Gmail's uniqueness rule.
    private var creating: [String: Task<GmailLabelInfo, any Error>] = [:]
    /// IDs still missing after a refresh: deleted labels, which Gmail strips from threads anyway.
    private var unlisted: Set<String> = []

    public init(api: any GmailLabelsAPI) {
        self.api = api
    }

    /// Cached snapshot; the first load is shared by concurrent callers. If `ids` contains IDs neither cached nor
    /// already known to be unlisted, refreshes once; IDs still unknown afterwards never trigger another refresh.
    public func snapshot(knowing ids: Set<String> = []) async throws -> LabelSnapshot {
        var snap = try await loaded()
        let missing = ids.filter { !snap.contains(id: $0) && !unlisted.contains($0) }
        if !missing.isEmpty {
            snap = try await refresh()
            unlisted.formUnion(missing.filter { !snap.contains(id: $0) })
        }
        return snap
    }

    /// Always calls labels.list and replaces the cache.
    @discardableResult
    public func refresh() async throws -> LabelSnapshot {
        let snap = LabelSnapshot(labels: try await api.listLabels())
        current = snap
        return snap
    }

    /// ID for `name`, creating it with `visibility` if missing. Concurrent calls for the same name share one create.
    /// On GmailError.http(409 or 400): refresh, adopt a case-insensitive match, else `createRejected`.
    public func ensureID(name: String, visibility: LabelVisibility) async throws -> String {
        _ = try await loaded()
        if let id = current?.id(forName: name) { return id }
        let key = name.lowercased()
        if let pending = creating[key] { return try await pending.value.id }
        let task = Task { try await self.createOrAdopt(name: name, visibility: visibility) }
        creating[key] = task
        defer { creating[key] = nil }
        return try await task.value.id
    }

    /// Makes sure each label exists, creating missing ones with `visibility` (`ensureID`). Never throws:
    /// returns the names it could not confirm (offline, refused, …), which the caller treats as missing.
    /// Cheap and idempotent: at most one labels.list per directory (none once loaded, none more when it
    /// fails), one labels.create per missing name. After an answer that would fail the rest as well
    /// (offline, rate limited, signed out, cancelled) the remaining names are not tried.
    public func ensureExisting(_ names: [String], visibility: LabelVisibility) async -> Set<String> {
        do {
            _ = try await loaded()
        } catch {
            log.error("labels not listed, \(names.count) not confirmed: \(String(describing: error), privacy: .public)")
            return Set(names)
        }
        var unconfirmed: Set<String> = []
        for (i, name) in names.enumerated() {
            do {
                _ = try await ensureID(name: name, visibility: visibility)
            } catch {
                log.error("label \(name, privacy: .public) not confirmed: \(String(describing: error), privacy: .public)")
                unconfirmed.insert(name)
                if GmailFailure.abortsPass(error) {
                    unconfirmed.formUnion(names[(i + 1)...])
                    break
                }
            }
        }
        return unconfirmed
    }

    /// labels.delete; 404 counts as success (another waker was first). Removes the ID from the cache.
    public func delete(id: String) async throws {
        do {
            try await api.deleteLabel(id: id)
        } catch let error where GmailFailure.isNotFound(error) {}
        current = current?.removing(id: id)
    }

    private func loaded() async throws -> LabelSnapshot {
        if let current { return current }
        if let loading { return try await loading.value }
        let task = Task { try await self.refresh() }
        loading = task
        defer { loading = nil }
        return try await task.value
    }

    private func createOrAdopt(name: String, visibility: LabelVisibility) async throws -> GmailLabelInfo {
        do {
            let info = try await api.createLabel(name: name, visibility: visibility)
            current = current?.inserting(info)
            return info
        } catch let error where GmailFailure.isCreateConflict(error) {
            let snap = try await refresh()
            if let id = snap.id(forName: name), let label = snap.label(id: id) { return label }
            throw LabelDirectoryError.createRejected(name: name, status: GmailFailure.status(error) ?? 0)
        }
    }
}
