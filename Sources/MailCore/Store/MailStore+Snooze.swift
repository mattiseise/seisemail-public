import Foundation

// Fork (seisemail): snooze from the thread list. The generic hook is in MailStore.swift.

public struct SnoozeTarget: Sendable, Equatable {
    /// Listed threads `snooze` would act on: the checked ones, else the selected one.
    public var threadIDs: Set<String>

    public init(threadIDs: Set<String>) {
        self.threadIDs = threadIDs
    }
}

@MainActor
extension MailStore {
    /// What `snooze` would act on now; nil when nothing listed is checked or selected.
    public var snoozeTarget: SnoozeTarget? {
        let ids = checkedIDs.isEmpty ? Set([selectedThreadID].compactMap { $0 }) : checkedIDs
        let listed = ids.intersection(threads.map(\.id))
        return listed.isEmpty ? nil : SnoozeTarget(threadIDs: listed)
    }

    /// Snoozes the checked threads, or the selected one, until `wakeAt` (rounded up to the minute). Undoable.
    /// Returns how many threads were snoozed (0: invalid time, no target, or failure).
    @discardableResult
    public func snooze(until wakeAt: Date, using service: SnoozeService) async -> Int {
        let wake: Date
        do {
            wake = try service.validatedWakeDate(wakeAt)
        } catch SnoozeError.wakeTimeOutOfRange {
            toast = "Torkutusaika ei kelpaa"
            return 0
        } catch {
            toast = "Torkutusaika on jo mennyt"
            return 0
        }
        // Only views that list the inbox lose the row; "-in:inbox" does not count. This predicate, not archive's
        // substring test, is the one to port.
        let listsInbox = SearchSyntax.hasPositiveTerm(activeQuery, "in:inbox") || SearchSyntax.hasPositiveTerm(activeQuery, "label:inbox")
        return await relabel(removesRow: listsInbox,
                             optimistic: LabelChange(add: [], remove: [GmailLabel.inbox]),
                             failureToast: "Torkutus epäonnistui") { threadID in
            let result = try await service.snooze(threadID: threadID, until: wake)
            return RelabelOutcome(applied: result.applied, undo: { try await service.undo(result) })
        }
    }
}
