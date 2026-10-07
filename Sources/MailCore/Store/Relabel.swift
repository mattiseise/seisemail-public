import Foundation
import Synchronization

/// What a `MailStore.relabel` action did on the server, and how to revert it.
struct RelabelOutcome: Sendable {
    /// Mirrored locally when the row stays.
    var applied: LabelChange
    /// Reverts on the server; returns the change it applied.
    var undo: @Sendable () async throws -> LabelChange
}

/// Collects per-thread values from runEach's Void closures.
final class ThreadResults<Value: Sendable>: Sendable {
    private let values = Mutex<[String: Value]>([:])

    init() {}

    func set(_ threadID: String, _ value: Value) {
        values.withLock { $0[threadID] = value }
    }

    subscript(threadID: String) -> Value? {
        values.withLock { $0[threadID] }
    }
}

/// What each thread's relabel did.
typealias RelabelResults = ThreadResults<RelabelOutcome>
/// What each thread's undo applied.
typealias LabelChangeResults = ThreadResults<LabelChange>
