import Foundation

// Fork (seisemail): empty states and notification taps. The load state itself is set in MailStore.swift.
@MainActor
extension MailStore {
    /// By the active saved view (fixed ID or equivalent query, `SeiseViews.kind`), and only without a search
    /// and with unchanged chips.
    public var listViewKind: ListViewKind {
        guard searchQuery == nil, !filtersChanged, let id = activeViewID,
              let view = views.first(where: { $0.id == id }) else { return .other }
        return SeiseViews.kind(of: view)
    }

    public var emptyState: ListEmptyState {
        .resolve(threadsEmpty: threads.isEmpty, needsSignIn: needsSignIn, load: listLoadState,
                 isOffline: isOffline, kind: listViewKind)
    }

    /// Notification and menu-bar taps: stay in the open view when it lists the thread, else openInInbox.
    public func openPreferringCurrentView(threadID: String) async {
        if threads.contains(where: { $0.id == threadID }) {
            await select(threadID: threadID)
        } else {
            await openInInbox(threadID: threadID)
        }
    }
}
