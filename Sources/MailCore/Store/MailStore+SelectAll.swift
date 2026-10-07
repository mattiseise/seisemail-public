// fork (seisemail): tri-state select-all for the thread list header.

/// How many of the loaded threads are checked.
/// The cases avoid the name `none`, which would clash with `Optional.none` in `CheckState?` contexts.
public enum CheckState: Sendable, Equatable {
    case unchecked
    case partial
    case all
}

extension MailStore {
    /// `.all` only when every loaded thread is checked; an empty list is always `.unchecked`.
    /// Rows appended by `loadMore` arrive unchecked, so `.all` turns into `.partial`.
    /// Counting only the checked IDs that are also loaded is deliberate: a stale ID left in
    /// `checkedIDs` must not count, so don't simplify this to `checkedIDs.count`.
    public var checkState: CheckState {
        let checked = threads.lazy.filter { self.checkedIDs.contains($0.id) }.count
        if checked == 0 { return .unchecked }
        return checked == threads.count ? .all : .partial
    }

    /// Clears the selection when every loaded thread is checked; otherwise checks them all (as ⌘A).
    /// Does nothing on an empty list, so an open peek stays open.
    public func toggleCheckAll() {
        guard !threads.isEmpty else { return }
        if checkState == .all { clearChecked() } else { checkAll() }
    }
}
