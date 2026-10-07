import Foundation

/// Holds fake API calls until the test opens it, so an overlap is set up by the test and not by a wall-clock window.
/// `wait()` records an arrival and suspends until `open()`; after `open()` it returns at once. Not cancellable:
/// a test that closes over a gate opens it before it ends.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Calls that reached the gate, held or not.
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Polls with Task.yield() until `n` calls have arrived; false after 5 s.
    @discardableResult
    func waitForArrivals(_ n: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while arrivals < n {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}
