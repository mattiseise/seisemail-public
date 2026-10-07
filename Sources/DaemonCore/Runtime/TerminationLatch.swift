import Synchronization

/// The bridge from the TERM/INT dispatch sources to the root task (§6.1 step 1, §6.8). The sources exist from
/// the first moment of `run`; a signal that arrives before the root task does is kept, and cancels the task as
/// soon as it is attached, so startup (lock, StartGuard, a slow safe-mode hook) never swallows a TERM.
public final class TerminationLatch: Sendable {
    private struct State {
        var requested = false
        var cancel: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    public init() {}

    /// A TERM or INT has arrived.
    public var isRequested: Bool { state.withLock { $0.requested } }

    /// From the signal handler: cancel the attached task, or the one attached later.
    public func request() {
        let cancel = state.withLock { s -> (@Sendable () -> Void)? in
            s.requested = true
            return s.cancel
        }
        cancel?()
    }

    public func attach<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>) {
        let requested = state.withLock { s -> Bool in
            s.cancel = { task.cancel() }
            return s.requested
        }
        if requested { task.cancel() }
    }
}
