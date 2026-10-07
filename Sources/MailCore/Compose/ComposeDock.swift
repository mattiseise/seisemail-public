import Foundation
import Observation

/// The in-window composer: at most one message at a time, shown as a bottom-right card,
/// minimized to its title bar, or expanded into a side peek.
@MainActor @Observable
public final class ComposeDock {
    public enum Mode: Equatable, Sendable { case card, minimized, peek }

    public private(set) var current: ComposeSession?
    public var mode: Mode = .card

    public init() {}

    /// Shows `session`; a message already open is closed first (kept as a draft if edited).
    public func present(_ session: ComposeSession) {
        current?.close()
        current = session
        mode = .card
    }

    public func dismiss() {
        current?.close()
        current = nil
    }

    public func discard() {
        current?.discard()
        current = nil
    }

    public func send() async throws {
        guard let session = current else { return }
        try await session.send()
        if current === session { current = nil }
    }
}
