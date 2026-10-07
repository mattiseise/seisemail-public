import Foundation

/// Whether the list on screen came from a successful load. Without it a failed load looks like an empty list.
public enum ListLoadState: Sendable, Equatable { case notLoaded, loaded, failed }

/// Fork views with their own empty state, recognised by view ID or an equivalent query (`SeiseViews.kind`).
public enum ListViewKind: Sendable, Equatable { case inboxZero, snoozed, other }

/// What the thread list shows instead of rows.
public enum ListEmptyState: Sendable, Equatable {
    case none, loading, inboxZero, snoozedEmpty, empty, offline, failed

    /// Not empty, or needsSignIn (LoginView takes over) → none; .notLoaded → loading;
    /// .failed → isOffline ? offline : failed; .loaded → by kind.
    /// Ignores `isLoading` on purpose: a stale reloadList can leave it true after a newer merge succeeded.
    public static func resolve(threadsEmpty: Bool, needsSignIn: Bool, load: ListLoadState,
                               isOffline: Bool, kind: ListViewKind) -> ListEmptyState {
        guard threadsEmpty, !needsSignIn else { return .none }
        switch load {
        case .notLoaded: return .loading
        case .failed: return isOffline ? .offline : .failed
        case .loaded:
            switch kind {
            case .inboxZero: return .inboxZero
            case .snoozed: return .snoozedEmpty
            case .other: return .empty
            }
        }
    }
}
