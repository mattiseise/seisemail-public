import Foundation
import Observation

/// Holds sent messages for a few seconds so they can be taken back ("Lähetetään… Peru").
/// Gmail has no undo-send; the delay is local. The draft file stays on disk until the
/// send succeeds (ComposeController deletes it), so a failure or crash loses nothing.
@MainActor @Observable
public final class PendingSends {
    public struct Item: Identifiable, Sendable {
        public var id: UUID { draft.id }
        public let draft: Draft
        public let deadline: Date
    }

    public private(set) var items: [Item] = []
    /// A message whose delay is over and whose send is still running.
    public var isSending: Bool { !inFlight.isEmpty }

    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// Failures of sends that were already running when `flush` started.
    @ObservationIgnored private var flushFailures: [Draft] = []
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let send: @MainActor (Draft) async throws -> Void
    @ObservationIgnored private let onFailure: @MainActor (Draft, Error) -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                send: @escaping @MainActor (Draft) async throws -> Void,
                onFailure: @escaping @MainActor (Draft, Error) -> Void) {
        self.sleep = sleep
        self.send = send
        self.onFailure = onFailure
    }

    public func enqueue(_ draft: Draft, delaySeconds: Int) async throws {
        guard delaySeconds > 0 else {
            try await send(draft)
            return
        }
        items.append(Item(draft: draft, deadline: Date().addingTimeInterval(TimeInterval(delaySeconds))))
        let sleep = self.sleep
        timers[draft.id] = Task { [weak self] in
            do { try await sleep(.seconds(delaySeconds)) } catch { return }
            await self?.deliver(draft.id)
        }
    }

    /// Takes the message back if it has not gone yet.
    public func cancel(id: UUID) -> Draft? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        timers.removeValue(forKey: id)?.cancel()
        return items.remove(at: index).draft
    }

    /// Sends everything still waiting, now, and waits for sends already running (on quit).
    /// Returns the drafts that failed to send; they are not passed to `onFailure`.
    public func flush() async -> [Draft] {
        isFlushing = true
        defer { isFlushing = false }
        for item in items {
            timers.removeValue(forKey: item.id)?.cancel()
        }
        var failed: [Draft] = []
        while let item = items.first {
            items.removeFirst()
            do { try await send(item.draft) } catch { failed.append(item.draft) }
        }
        for task in inFlight.values { await task.value }
        failed += flushFailures
        flushFailures = []
        return failed
    }

    /// Waits for running timers (tests).
    public func settle() async {
        for task in timers.values { await task.value }
    }

    /// Runs inside the draft's timer task once its delay is over.
    private func deliver(_ id: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let draft = items.remove(at: index).draft
        inFlight[id] = timers.removeValue(forKey: id)
        defer { inFlight[id] = nil }
        do {
            try await send(draft)
        } catch {
            if isFlushing { flushFailures.append(draft) } else { onFailure(draft, error) }
        }
    }
}
