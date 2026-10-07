import Foundation
import Synchronization
import Testing
@testable import MailCore

/// A clock that only moves when a test advances it. Sleepers wake in deadline order; a cancelled
/// sleeper throws `CancellationError` at once, like `Task.sleep`.
final class ManualClock: MeetingHintsClock, Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { s in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    s.sleepers.append(Sleeper(id: id, deadline: s.now + duration, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time to the earliest sleeper's deadline and wakes it; false if nobody sleeps.
    @discardableResult
    func advanceToNextDeadline() -> Bool {
        guard let next = state.withLock({ s in s.sleepers.map(\.deadline).min().map { $0 - s.now } }) else { return false }
        advance(by: next)
        return true
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now += duration
            let due = s.sleepers.filter { $0.deadline <= s.now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Waits (in real time, at most 2 s) until `condition` holds; records a test issue otherwise.
@MainActor
func eventually(_ what: String = "condition", _ condition: () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for \(what)")
}

/// The task's value, cancelling it (and recording an issue) if it is not done within 2 s of real
/// time, so a regression fails the test instead of hanging the run.
@MainActor
func valueWithin<T: Sendable>(_ task: Task<T, Never>, _ what: String = "refresh") async -> T {
    let watchdog = Task {
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        Issue.record("Timed out waiting for \(what)")
    }
    let value = await task.value
    watchdog.cancel()
    return value
}
