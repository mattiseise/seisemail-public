import Foundation

/// A manual clock for loops that take `sleep: @Sendable (Duration) async throws -> Void`.
/// Each call records its duration and suspends until `step()` resumes the oldest waiting call. A cancelled caller
/// throws CancellationError and is counted in `cancellations`.
actor StepSleeper {
    /// Every requested duration, in call order (cancelled calls included).
    private(set) var requests: [Duration] = []
    /// Calls that ended with CancellationError.
    private(set) var cancellations = 0
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID = 0

    /// Calls suspended right now.
    var pendingCount: Int { waiting.count }

    /// The closure to hand to the code under test.
    nonisolated var closure: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await self.sleep(duration) }
    }

    func sleep(_ duration: Duration) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Recorded together with the enqueue, so `waitForRequests(n)` implies the n-th call is waiting.
                requests.append(duration)
                if Task.isCancelled {
                    cancellations += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let entry = waiting.remove(at: index)
        cancellations += 1
        entry.continuation.resume(throwing: CancellationError())
    }

    /// Resumes the oldest waiting call. Waits briefly for one to arrive; false if none did.
    @discardableResult
    func step() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while waiting.isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        waiting.removeFirst().continuation.resume()
        return true
    }

    /// Polls with Task.yield() until `n` calls have been requested; false after 5 s.
    @discardableResult
    func waitForRequests(_ n: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while requests.count < n {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    /// Polls until `n` calls have thrown CancellationError; false after 5 s.
    @discardableResult
    func waitForCancellations(_ n: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while cancellations < n {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}
