import Foundation
import Synchronization

/// Parks fake API calls at a known point until the test opens it, so a test can act "while a
/// request is in flight" without betting on a wall-clock delay being long enough on a loaded
/// machine. Closed when created; once opened it stays open. Like `Task.sleep`, a parked call
/// throws `CancellationError` when its task is cancelled.
///
/// Typical use: close the gate, start the action, wait (`eventually`) until the fake has recorded
/// the calls the test depends on, act, then `open()` and await the action.
final class CallGate: Sendable {
    private struct State {
        var isOpen = false
        var parked: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    /// Calls currently waiting at the gate.
    var parkedCount: Int { state.withLock { $0.parked.count } }

    /// Lets every parked call and every later one through.
    func open() {
        let parked = state.withLock { s in
            s.isOpen = true
            defer { s.parked = [:] }
            return Array(s.parked.values)
        }
        for continuation in parked { continuation.resume() }
    }

    /// Returns at once when open; otherwise waits for `open()` or cancellation.
    func pass() async throws {
        enum Entry { case through, parked, cancelled }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let entry = state.withLock { s -> Entry in
                    if s.isOpen { return .through }
                    // Checked under the lock: a cancel either finds this call parked or comes before it.
                    if Task.isCancelled { return .cancelled }
                    s.parked[id] = continuation
                    return .parked
                }
                switch entry {
                case .through: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            state.withLock { $0.parked.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}
