import Foundation
import Observation

/// Lifecycle of one compose window's draft: autosave, close, discard and send, such that a sent
/// or discarded draft can never be written back and an untouched reply leaves nothing behind.
@MainActor @Observable
public final class ComposeSession {
    public enum State: Equatable, Sendable { case editing, sending, sent, discarded }

    public var draft: Draft
    public private(set) var state: State = .editing

    @ObservationIgnored private let initialContent: Draft.Content
    @ObservationIgnored private let store: DraftStore
    @ObservationIgnored private let keepOnClose: Bool
    @ObservationIgnored private let sender: @MainActor (Draft) async throws -> Void

    /// - Parameter keepOnClose: true for drafts restored from disk, which stay saved even if untouched.
    public init(draft: Draft, store: DraftStore, keepOnClose: Bool = false, send: @escaping @MainActor (Draft) async throws -> Void) {
        self.draft = draft
        self.initialContent = draft.content
        self.store = store
        self.keepOnClose = keepOnClose
        self.sender = send
    }

    public var isDirty: Bool { draft.content != initialContent }

    /// Identity for the autosave timer; unaffected by saving.
    public var autosaveKey: Draft.Content { draft.content }

    public func autosave() {
        guard state == .editing, isDirty else { return }
        save()
    }

    public func close() {
        guard state == .editing else { return }
        if isDirty {
            save()
        } else if !keepOnClose {
            store.delete(id: draft.id)
        }
    }

    public func discard() {
        state = .discarded
        store.delete(id: draft.id)
    }

    public func send() async throws {
        guard state == .editing else { return }
        save() // a failed send leaves the draft on disk
        state = .sending
        do {
            try await sender(draft)
            state = .sent
        } catch {
            state = .editing
            throw error
        }
    }

    private func save() {
        var copy = draft
        copy.updatedAt = Date()
        try? store.save(copy)
    }
}
