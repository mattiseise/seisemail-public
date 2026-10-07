import Foundation
import os

private let log = Logger(subsystem: "fi.mak8r.mail", category: "snooze")

public struct WakeReport: Sendable, Equatable {
    /// Another pass of this waker was running.
    public var skipped = false
    /// Rules 3 and 4, in processing order.
    public var woken: [String] = []
    /// Rules 1 and 2.
    public var cancelled: [String] = []
    public var failedThreadIDs: [String] = []
    /// Cleanup results; always empty unless `Options.cleansUp`.
    public var deletedLabelIDs: [String] = []
    public var failedLabelIDs: [String] = []
    /// Earliest wake among threads not yet due: when the daemon needs to look again.
    public var nextWakeAt: Date?
    /// False if `Options.maxPages` stopped the listing.
    public var listingComplete = true

    public init() {}
}

/// Wakes snoozed threads of one account (conventions §1 "Herätys"). Daemon: every 60 s; apps: at launch and every 5 min.
/// Only the daemon cleans up time labels (`Options.cleansUp`).
public actor SnoozeWaker {
    public struct Options: Sendable, Equatable {
        public var pageSize = 500
        public var maxPages = 20
        public var cleanupMargin: TimeInterval = 300
        /// Delete due time labels after waking (conventions §1 "Siivous"). Only the Mac mini daemon sets this: its
        /// clock is NTP-synced. Clients (Mac app, Windows) never delete labels. When false the pass performs no
        /// cleanup at all: no labels.delete, and the report's cleanup fields stay empty.
        public var cleansUp = false

        public init(pageSize: Int = 500, maxPages: Int = 20, cleanupMargin: TimeInterval = 300, cleansUp: Bool = false) {
            self.pageSize = pageSize
            self.maxPages = maxPages
            self.cleanupMargin = cleanupMargin
            self.cleansUp = cleansUp
        }
    }

    private let api: any GmailLabelsAPI
    private let directory: LabelDirectory
    private let scheme: SnoozeLabelScheme
    private let options: Options
    private let now: @Sendable () -> Date
    /// Actor reentrancy alone would interleave overlapping passes.
    private var running = false

    public init(api: any GmailLabelsAPI, directory: LabelDirectory, scheme: SnoozeLabelScheme = .standard,
                options: Options = Options(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.directory = directory
        self.scheme = scheme
        self.options = options
        self.now = now
    }

    /// One pass: rules 0–4, then cleanup if `Options.cleansUp`. Throws for labels.list and threads.list failures and for errors that
    /// end the pass (offline, auth; cancellation, also URLError(.cancelled), as CancellationError); other per-thread
    /// and per-label errors land in the report.
    public func runOnce() async throws -> WakeReport {
        var report = WakeReport()
        guard !running else {
            report.skipped = true
            return report
        }
        running = true
        defer { running = false }
        do {
            try await pass(now: self.now(), report: &report)   // one instant for the whole pass
        } catch {
            throw GmailFailure.passAbort(error)
        }
        return report
    }

    private func pass(now: Date, report: inout WakeReport) async throws {
        let snapshot = try await directory.refresh()
        if let markerID = snapshot.id(forName: scheme.marker) {
            var ids: [String] = []
            var token: String?
            var pages = 0
            repeat {
                let page = try await api.listThreadIDs(labelIDs: [markerID], includeSpamTrash: true,
                                                       pageToken: token, maxResults: options.pageSize)
                ids += page.ids
                token = page.nextPageToken
                pages += 1
            } while token != nil && pages < options.maxPages
            report.listingComplete = token == nil
            var seen: Set<String> = []
            for id in ids where seen.insert(id).inserted {
                do {
                    try Task.checkCancellation()
                    try await process(id, markerID: markerID, now: now, report: &report)
                } catch let error where GmailFailure.abortsPass(error) {
                    throw error
                } catch {
                    log.error("wake \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    report.failedThreadIDs.append(id)
                }
            }
        }
        // Daemon only. Cleanup then runs even without a marker label or after a partial listing.
        guard options.cleansUp else { return }
        let names = try await directory.snapshot().namesByID
        for labelID in WakePlanner.cleanupCandidates(namesByID: names, scheme: scheme, now: now, margin: options.cleanupMargin) {
            do {
                try Task.checkCancellation()
                try await directory.delete(id: labelID)
                report.deletedLabelIDs.append(labelID)
            } catch let error where GmailFailure.abortsPass(error) {
                throw error
            } catch {
                log.error("delete label \(labelID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                report.failedLabelIDs.append(labelID)
            }
        }
    }

    /// Fetch → decide → modify at once, so the read-to-write gap stays short. Same retry-once rule as SnoozeService.
    /// The scan reads through the read cache (the listing just vouched for unchanged threads); a thread
    /// whose cached labels call for a change is read again from Gmail and decided anew before any write.
    private func process(_ id: String, markerID: String, now: Date, report: inout WakeReport) async throws {
        var previous: (change: LabelChange, error: any Error)?
        var fresh = false
        while true {
            let thread: ThreadLabels
            do {
                thread = try await api.threadLabels(id: id, fresh: fresh)
            } catch let error where GmailFailure.isNotFound(error) {
                return                                    // the thread is gone
            }
            // Refreshes when a label appeared after the pass started; otherwise rule 4 would wake the thread early.
            let snapshot = try await directory.snapshot(knowing: thread.labelIDs)
            let decision = WakePlanner.decide(threadID: id, labelIDs: thread.labelIDs, markerID: markerID,
                                              namesByID: snapshot.namesByID, scheme: scheme, now: now)
            if decision.rule == .notDue, let wakeAt = decision.wakeAt {
                report.nextWakeAt = min(report.nextWakeAt ?? wakeAt, wakeAt)
            }
            guard let change = decision.change else { return }
            if !fresh {
                fresh = true
                continue
            }
            if let previous, previous.change == change { throw previous.error }
            do {
                try await api.modify(threadID: id, add: change.add, remove: change.remove)
                if decision.rule == .due || decision.rule == .noValidTimeLabel {
                    report.woken.append(id)
                } else {
                    report.cancelled.append(id)
                }
                return
            } catch let error where previous == nil && GmailFailure.mayBeStaleLabelID(error) {
                previous = (change, error)
                try await directory.refresh()
            }
        }
    }
}
