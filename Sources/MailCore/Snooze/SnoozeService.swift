import Foundation

public enum SnoozeError: Error, Equatable, Sendable {
    /// The wake time, rounded up to the minute, is not after now.
    case wakeTimeNotInFuture
    /// After `SnoozeTime.latest`.
    case wakeTimeOutOfRange
}

public struct SnoozeResult: Sendable, Equatable {
    public var threadID: String
    /// The whole minute actually encoded.
    public var wakeAt: Date
    public var timeLabelName: String
    /// The modify that succeeded.
    public var applied: LabelChange
    /// From the fresh fetch the successful modify was computed from.
    public var before: SnoozeState

    public init(threadID: String, wakeAt: Date, timeLabelName: String, applied: LabelChange, before: SnoozeState) {
        self.threadID = threadID
        self.wakeAt = wakeAt
        self.timeLabelName = timeLabelName
        self.applied = applied
        self.before = before
    }
}

/// Snooze and undo for one account (conventions §1 "Torkutus"). Stateless; safe to share.
public struct SnoozeService: Sendable {
    public let api: any GmailLabelsAPI
    public let directory: LabelDirectory
    public let scheme: SnoozeLabelScheme
    public let now: @Sendable () -> Date

    public init(api: any GmailLabelsAPI, directory: LabelDirectory, scheme: SnoozeLabelScheme = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.directory = directory
        self.scheme = scheme
        self.now = now
    }

    /// `date` rounded up to the minute; throws unless it is after now and encodable.
    public func validatedWakeDate(_ date: Date) throws -> Date {
        let wake = SnoozeTime.ceilToMinute(date)
        if wake > SnoozeTime.latest { throw SnoozeError.wakeTimeOutOfRange }
        guard wake > now() else { throw SnoozeError.wakeTimeNotInFuture }
        return wake
    }

    /// Exactly one successful threads.modify, with the conventions §0 retry-once rule.
    public func snooze(threadID: String, until wakeAt: Date) async throws -> SnoozeResult {
        let wake = try validatedWakeDate(wakeAt)
        let timeName = scheme.timeLabelName(for: wake)
        var previous: (change: LabelChange, error: any Error)?
        while true {
            let thread = try await api.threadLabels(id: threadID)
            _ = try await directory.snapshot(knowing: thread.labelIDs)
            // Marker first, then time: deterministic label creation order.
            let markerID = try await directory.ensureID(name: scheme.marker, visibility: scheme.markerVisibility)
            let timeID = try await directory.ensureID(name: timeName, visibility: scheme.timeVisibility)
            let names = try await directory.snapshot().namesByID
            let before = SnoozeOperation.state(of: thread.labelIDs, markerID: markerID, namesByID: names, scheme: scheme)
            let change = SnoozeOperation.snoozeChange(current: thread.labelIDs, markerID: markerID, timeLabelID: timeID,
                                                      namesByID: names, scheme: scheme)
            if let previous, previous.change == change { throw previous.error }
            do {
                try await api.modify(threadID: threadID, add: change.add, remove: change.remove)
                return SnoozeResult(threadID: threadID, wakeAt: wake, timeLabelName: timeName, applied: change, before: before)
            } catch let error where previous == nil && GmailFailure.mayBeStaleLabelID(error) {
                // The next round re-fetches and re-ensures, which recreates a label deleted elsewhere.
                previous = (change, error)
                try await directory.refresh()
            }
        }
    }

    /// Restores `result.before`, recreating time labels deleted meanwhile. Returns the change applied, empty if
    /// there was nothing to do.
    public func undo(_ result: SnoozeResult) async throws -> LabelChange {
        let target = result.before
        var previous: (change: LabelChange, error: any Error)?
        while true {
            let thread = try await api.threadLabels(id: result.threadID)
            let snapshot = try await directory.snapshot(knowing: thread.labelIDs)
            let markerID = target.marked
                ? try await directory.ensureID(name: scheme.marker, visibility: scheme.markerVisibility)
                : snapshot.id(forName: scheme.marker)
            var targetIDs: [String: String] = [:]
            for name in target.timeLabelNames {
                targetIDs[name] = try await directory.ensureID(name: name, visibility: scheme.timeVisibility)
            }
            let names = try await directory.snapshot().namesByID
            let change = SnoozeOperation.undoChange(target: target, current: thread.labelIDs, markerID: markerID,
                                                    targetTimeLabelIDs: targetIDs, namesByID: names, scheme: scheme)
            if change.isEmpty { return change }
            if let previous, previous.change == change { throw previous.error }
            do {
                try await api.modify(threadID: result.threadID, add: change.add, remove: change.remove)
                return change
            } catch let error where previous == nil && GmailFailure.mayBeStaleLabelID(error) {
                previous = (change, error)
                try await directory.refresh()
            }
        }
    }
}
