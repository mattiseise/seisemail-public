import Foundation
import Synchronization
@testable import MailCore

/// Virtual time that only moves when the test calls `advance(by:)` or `advance(to:)`.
final class ManualQuotaClock: QuotaClock, Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var sleepers: [Sleeper] = []
        var jitter = 0.0
    }

    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }
    var wallNow: Date { Self.epoch.addingTimeInterval(now / .seconds(1)) }
    func jitter() -> Double { state.withLock { $0.jitter } }
    func setJitter(_ value: Double) { state.withLock { $0.jitter = value } }

    /// The earliest pending sleep, if any.
    var nextDeadline: Duration? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    func sleep(until deadline: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let due = state.withLock { s -> Bool in
                if deadline <= s.now { return true }
                s.sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
                return false
            }
            if due { continuation.resume() }
        }
    }

    func advance(by delta: Duration) {
        advance(to: now + delta)
    }

    func advance(to time: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = max(s.now, time)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Virtual time that jumps straight to any deadline someone sleeps until. Waiting costs nothing,
/// so whole store flows with minutes of pacing run instantly while timestamps stay meaningful.
/// Deadline-only timers (`sleepForDeadline`) don't jump: they fire once time gets there anyway.
final class SkipAheadQuotaClock: QuotaClock, Sendable {
    private struct State {
        var now: Duration = .zero
        var jitter = 0.0
        var deadlineSleepers: [(deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
        var stillGate: CallGate?
    }

    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }
    var wallNow: Date { ManualQuotaClock.epoch.addingTimeInterval(now / .seconds(1)) }
    func jitter() -> Double { state.withLock { $0.jitter } }
    func setJitter(_ value: Double) { state.withLock { $0.jitter = value } }

    func advance(by delta: Duration) { move(to: now + delta) }

    /// Stops time until the returned gate is opened: sleepers park instead of jumping ahead.
    /// Because a jump costs no real time, a task the OS runs a few milliseconds late could
    /// otherwise start (and take its 90 s deadline) whole cooldowns after its siblings; holding
    /// time until every concurrent request has started keeps their deadlines equal, as on a real clock.
    func holdTime() -> CallGate {
        let gate = CallGate()
        state.withLock { $0.stillGate = gate }
        return gate
    }

    func sleep(until deadline: Duration) async throws {
        try await state.withLock { $0.stillGate }?.pass()
        move(to: deadline)
        await Task.yield()
    }

    func sleepForDeadline(until deadline: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let due = state.withLock { s -> Bool in
                if deadline <= s.now { return true }
                s.deadlineSleepers.append((deadline, continuation))
                return false
            }
            if due { continuation.resume() }
        }
    }

    private func move(to time: Duration) {
        let due = state.withLock { s in
            s.now = max(s.now, time)
            let now = s.now
            let due = s.deadlineSleepers.filter { $0.deadline <= now }
            s.deadlineSleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Polls `condition` (yielding, then briefly sleeping) for up to about two seconds of real time.
@discardableResult
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for i in 0..<2_000 {
        if await condition() { return true }
        if i < 50 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
    }
    return await condition()
}
