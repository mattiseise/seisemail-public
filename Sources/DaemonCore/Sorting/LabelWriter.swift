import Foundation
import MailCore

/// Sends a sorting decision as one `threads.modify` (add only; the daemon never removes a `Lajittelu/*`
/// label). Conventions §0 retry-once: a 400/404 on modify refreshes the label cache, re-reads the thread
/// fresh, re-decides, and resends once only if the change differs; otherwise the first error stands.
public struct LabelWriter: Sendable {
    private let api: any GmailSyncAPI
    private let directory: LabelDirectory

    public init(api: any GmailSyncAPI, directory: LabelDirectory) {
        self.api = api
        self.directory = directory
    }

    /// The marker is created hidden, every other label shown (conventions §2).
    public static func visibility(for name: String) -> LabelVisibility {
        name.lowercased() == SeiseLabels.Sorting.classifiedMarker.lowercased() ? .hidden : .shown
    }

    /// Returns the names added (`[]` when nothing was sent).
    @discardableResult
    public func apply(_ d: SortingDecision, thread: ThreadHeaders,
                      redecide: @Sendable (ThreadHeaders, LabelSnapshot) -> SortingDecision) async throws -> [String] {
        let names = d.addNames
        guard !names.isEmpty else { return [] }
        let ids = try await resolve(names)
        do {
            try await api.modify(threadID: thread.threadID, add: ids, remove: [])
            return names
        } catch let first where GmailFailure.mayBeStaleLabelID(first) {
            try await directory.refresh()
            let fresh: ThreadHeaders
            do {
                fresh = try await api.threadHeaders(id: thread.threadID, headers: DaemonHeaders.thread)
            } catch let error where GmailFailure.isNotFound(error) {
                return []                                         // the thread is gone
            }
            let snapshot = try await directory.snapshot(knowing: fresh.labelIDs)
            let again = redecide(fresh, snapshot)
            let againNames = again.addNames
            guard !againNames.isEmpty else { return [] }
            let againIDs = try await resolve(againNames)
            if againIDs == ids { throw first }
            try await api.modify(threadID: thread.threadID, add: againIDs, remove: [])
            return againNames
        }
    }

    private func resolve(_ names: [String]) async throws -> [String] {
        var ids: [String] = []
        for name in names {
            let id = try await directory.ensureID(name: name, visibility: Self.visibility(for: name))
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}
