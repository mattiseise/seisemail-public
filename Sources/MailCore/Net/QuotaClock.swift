import Foundation

/// Time for the quota scheduler; tests swap in a virtual clock.
public protocol QuotaClock: Sendable {
    /// Monotonic time since an arbitrary origin.
    var now: Duration { get }
    /// Wall-clock time, only for HTTP-date `Retry-After` values.
    var wallNow: Date { get }
    func sleep(until deadline: Duration) async throws
    /// A timer that only enforces a deadline: nothing needs it to make progress. A virtual clock
    /// that jumps to every `sleep(until:)` can let these wait until time gets there by itself.
    func sleepForDeadline(until deadline: Duration) async throws
    /// A random number in 0..<1.
    func jitter() -> Double
}

extension QuotaClock {
    public func sleepForDeadline(until deadline: Duration) async throws {
        try await sleep(until: deadline)
    }
}

public struct SystemQuotaClock: QuotaClock {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public var now: Duration { ContinuousClock.now - origin }
    public var wallNow: Date { Date() }

    public func sleep(until deadline: Duration) async throws {
        try await ContinuousClock().sleep(until: origin + deadline, tolerance: .milliseconds(50))
    }

    public func jitter() -> Double { Double.random(in: 0..<1) }
}
