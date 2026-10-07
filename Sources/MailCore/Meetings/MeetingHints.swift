import Foundation
import Observation

/// Time for `MeetingHints`: a monotonic `now` (any origin) and a cancellable sleep. Injected so
/// tests can drive the debounce, start-up delay and backoff without waiting.
public protocol MeetingHintsClock: Sendable {
    var now: Duration { get }
    func sleep(for duration: Duration) async throws
}

public struct ContinuousMeetingHintsClock: MeetingHintsClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration { origin.duration(to: .now) }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Which list rows have a meeting link.
///
/// Sources, strongest first:
/// 1. a body already parsed for the reading pane or the thread cache (exact, while the thread's
///    message count is unchanged; no API cost);
/// 2. a Gmail search hit (delivery B): one `threads.list` per service, 3 × 10 units, only when the
///    list shows a row (thread id and message count) that no search has covered yet, and at most
///    once a minute. Results are kept per thread, so they hold in every view that shows it;
/// 3. the subject and snippet already in the summary (no API cost).
///
/// One instance per account: thread ids are per account.
///
/// Fork (seisemail). Display only: nothing is labelled or opened from here, and the only API call
/// is the search in `refresh`.
@MainActor @Observable
public final class MeetingHints {
    /// Quiet time after the last list change before searching.
    public static let debounce: Duration = .seconds(2)
    /// No searches during the sign-in burst after start.
    public static let startupDelay: Duration = .seconds(60)
    /// No searches for this long after a 403 or 429.
    public static let backoff: Duration = .seconds(120)

    /// Behind the quota transport Gmail's limit arrives as `.rateLimited`; unwrapped clients surface the raw 403/429.
    static func isRateLimit(_ error: Error) -> Bool {
        if (error as? GmailError) == .rateLimited { return true }
        if case GmailError.http(let status, _) = error { return status == 403 || status == 429 }
        return false
    }

    /// At most one search (3 calls, 30 units) per this interval, however often the list changes.
    public static let minInterval: Duration = .seconds(60)
    /// One page per service: `threads.list` costs 10 units whatever its size.
    static let maxResults = 500
    /// Search results kept for threads no longer shown, before they are dropped.
    static let maxRemembered = 5_000

    public enum RefreshOutcome: Equatable, Sendable {
        /// Every row was covered by a search at its current message count, in any view: no calls.
        case unchanged
        /// No scope or no rows: no calls.
        case nothingToSearch
        /// A newer list change took over or the caller was cancelled before searching; nothing was
        /// committed.
        case superseded
        case refreshed
        /// Gmail said 403/429; no searches until the backoff has passed.
        case rateLimited
        /// Any other error (offline, 5xx …): nothing committed, retried on the next list change.
        case failed
    }

    /// What a search depends on: the list's own query and its rows with their message counts.
    public struct ListSignature: Hashable, Sendable {
        struct Row: Hashable, Sendable { var id: String; var messageCount: Int }
        let scope: String
        let rows: [Row]
    }

    private struct Confirmed { var messageCount: Int; var link: MeetingLink? }
    private struct SnippetKey: Hashable { var subject: String; var snippet: String }

    /// Body results by thread id. Observed: a new result redraws the rows that show it.
    private var confirmed: [String: Confirmed] = [:]
    /// Search hits by thread id, from the latest search that covered each thread. Observed, and only
    /// reassigned when a hit changes.
    private var searchHits: [String: MeetingService] = [:]
    /// The message count each thread had in the latest search that covered it, hit or not.
    @ObservationIgnored private var searched: [String: Int] = [:]
    /// Snippet hints are recomputed only when a row's subject or snippet changes, not per redraw.
    @ObservationIgnored private var snippetHints: [String: (key: SnippetKey, service: MeetingService?)] = [:]

    @ObservationIgnored private let clock: any MeetingHintsClock
    @ObservationIgnored private let startedAt: Duration
    @ObservationIgnored private var backoffUntil: Duration?
    @ObservationIgnored private var lastSearchStart: Duration?
    /// Bumped by every refresh; a refresh still waiting (debounce, spacing) stops when it sees a
    /// newer number.
    @ObservationIgnored private var generation = 0

    private struct InFlight {
        let id: Int
        let rows: Set<ListSignature.Row>
        let task: Task<RefreshOutcome, Never>
    }
    /// The search in progress. It is not cancelled with its caller (its units are spent anyway); a
    /// newer list it covers waits for it, and a newer search waits for it, so calls never overlap.
    @ObservationIgnored private var inFlight: InFlight?
    /// The search whose results are still wanted; a list it does not cover stops it after its call.
    @ObservationIgnored private var wantedSearch: Int?
    @ObservationIgnored private var searchCount = 0

    /// For tests: how many bodies and snippets were actually parsed.
    @ObservationIgnored private(set) var parseCount = 0
    @ObservationIgnored private(set) var snippetParseCount = 0
    var searchHitCount: Int { searchHits.count }

    /// `startedAt`: when the app started (the start-up delay counts from it); now by default.
    public init(clock: any MeetingHintsClock = ContinuousMeetingHintsClock(), startedAt: Duration? = nil) {
        self.clock = clock
        self.startedAt = startedAt ?? clock.now
    }

    public func service(for summary: ThreadSummary) -> MeetingService? {
        if let c = confirmed[summary.id], c.messageCount == summary.messageCount { return c.link?.service }
        if let hit = searchHits[summary.id] { return hit }
        return snippetHint(for: summary)
    }

    /// The body link for this row, if its thread was parsed at its current message count.
    public func link(for summary: ThreadSummary) -> MeetingLink? {
        link(threadID: summary.id, messageCount: summary.messageCount)
    }

    /// The body link recorded for this thread at exactly this message count.
    public func link(threadID: String, messageCount: Int) -> MeetingLink? {
        guard let c = confirmed[threadID], c.messageCount == messageCount else { return nil }
        return c.link
    }

    /// Parses a thread's bodies once per (thread, message count); the result then decides the
    /// row's badge. Returns the link for the reading pane's join button. Call outside view bodies.
    @discardableResult
    public func record(_ thread: MailThread) -> MeetingLink? {
        if let c = confirmed[thread.id], c.messageCount == thread.messages.count { return c.link }
        parseCount += 1
        let link = MeetingLinkDetector.primaryLink(in: thread)
        confirmed[thread.id] = Confirmed(messageCount: thread.messages.count, link: link)
        return link
    }

    private func snippetHint(for summary: ThreadSummary) -> MeetingService? {
        let key = SnippetKey(subject: summary.subject, snippet: summary.snippet)
        if let cached = snippetHints[summary.id], cached.key == key { return cached.service }
        snippetParseCount += 1
        let service = MeetingLinkDetector.snippetHint(subject: summary.subject, snippet: summary.snippet)
        snippetHints[summary.id] = (key, service)
        return service
    }

    // MARK: - Gmail search (delivery B)

    /// The value a view keys its refresh task on; nil when there is nothing to search.
    public static func signature(query: String?, threads: [ThreadSummary]) -> ListSignature? {
        guard let query, !threads.isEmpty else { return nil }
        // Order does not change what a search finds.
        let rows = threads.map { ListSignature.Row(id: $0.id, messageCount: $0.messageCount) }
            .sorted { $0.id < $1.id }
        return ListSignature(scope: query, rows: rows)
    }

    /// Keeps the search hits current for this list: one attempt, and after a 403/429 another one
    /// once the backoff has passed, until it succeeds, fails otherwise, or the task is cancelled.
    /// `api` must be this account's client.
    public func refresh(api: GmailAPI, query: String?, threads: [ThreadSummary]) async {
        while !Task.isCancelled {
            guard await refreshOnce(api: api, query: query, threads: threads) == .rateLimited else { return }
        }
    }

    /// One attempt: nothing if every row was covered by a search at its current message count;
    /// waits for a search in flight that covers the rows still missing; otherwise waits for the
    /// debounce (and for the start-up delay, any backoff, the one-minute spacing and the previous
    /// search), then searches each service in turn and commits the results only if all searches
    /// succeed and no newer list stopped it.
    func refreshOnce(api: GmailAPI, query: String?, threads: [ThreadSummary]) async -> RefreshOutcome {
        // The latest call wins: whatever it finds, an older refresh still waiting is now stale.
        generation += 1
        let mine = generation
        guard let signature = Self.signature(query: query, threads: threads) else { return .nothingToSearch }
        // Rows removed (archiving during triage), put back as they were, or already searched in
        // another view: every row's result is known.
        let missing = missingRows(signature)
        if missing.isEmpty { return .unchanged }
        if let current = inFlight, wantedSearch == current.id, missing.isSubset(of: current.rows) {
            // Rows were only removed since the search in flight started: its results are enough.
            return await current.task.value
        }
        // A search in flight does not cover this list: stop it after its call in flight.
        wantedSearch = nil
        do {
            try await clock.sleep(for: Self.debounce)
            while true {
                // Strictly sequential calls: let an older search finish its call in flight first;
                // it may also have started a backoff.
                while let previous = inFlight { _ = await previous.task.value }
                guard mine == generation else { return .superseded }
                let notBefore = max(startedAt + Self.startupDelay, backoffUntil ?? .zero,
                                    lastSearchStart.map { $0 + Self.minInterval } ?? .zero)
                let wait = notBefore - clock.now
                if wait <= .zero { break }
                try await clock.sleep(for: wait)
            }
        } catch {
            return .superseded
        }
        guard mine == generation, !Task.isCancelled else { return .superseded }
        if missingRows(signature).isEmpty { return .unchanged }

        searchCount += 1
        let id = searchCount
        let task = Task {
            let outcome = await self.search(id: id, api: api, signature: signature)
            if self.inFlight?.id == id { self.inFlight = nil }
            return outcome
        }
        inFlight = InFlight(id: id, rows: Set(signature.rows), task: task)
        wantedSearch = id
        // Not cancelled with this caller: the search runs to its end or until a newer list stops it.
        return await task.value
    }

    private func missingRows(_ signature: ListSignature) -> Set<ListSignature.Row> {
        Set(signature.rows.filter { searched[$0.id] != $0.messageCount })
    }

    private func search(id searchID: Int, api: GmailAPI, signature: ListSignature) async -> RefreshOutcome {
        lastSearchStart = clock.now
        let visible = Set(signature.rows.map(\.id))
        var hits: [String: MeetingService] = [:]
        for service in MeetingService.allCases {
            let query = MeetingLinkDetector.searchQuery(service: service, scope: signature.scope)
            do {
                // One request per call: this search has its own backoff, the client must not retry.
                let page = try await api.listThreadsOnce(query: query, pageToken: nil, maxResults: Self.maxResults)
                // Message content is untrusted: a hit only picks a badge, the first service wins.
                for id in page.ids where visible.contains(id) && hits[id] == nil { hits[id] = service }
            } catch {
                // The quota belongs to the account, not to this list: back off even if a newer
                // list has taken over.
                if Self.isRateLimit(error) {
                    backoffUntil = clock.now + Self.backoff
                    return .rateLimited
                }
                return wantedSearch == searchID ? .failed : .superseded
            }
            guard wantedSearch == searchID else { return .superseded }
        }
        commit(hits, for: signature, visible: visible)
        return .refreshed
    }

    /// Merges a completed search into the per-thread results: every row it covered gets its new
    /// result, other threads keep theirs.
    private func commit(_ hits: [String: MeetingService], for signature: ListSignature, visible: Set<String>) {
        var merged = searchHits
        for row in signature.rows {
            searched[row.id] = row.messageCount
            merged[row.id] = hits[row.id]
        }
        if searched.count > Self.maxRemembered {
            searched = searched.filter { visible.contains($0.key) }
            merged = merged.filter { visible.contains($0.key) }
        }
        if merged != searchHits { searchHits = merged }
    }
}

/// One `MeetingHints` per account, keyed by lower-cased address. Not observed itself; the hints
/// inside are.
@MainActor
public final class MeetingHintsRegistry {
    public static let shared = MeetingHintsRegistry()

    private let clock: any MeetingHintsClock
    /// The start-up delay counts from here for every account, also one first shown much later.
    private let startedAt: Duration
    private var byAccount: [String: MeetingHints] = [:]

    public init(clock: any MeetingHintsClock = ContinuousMeetingHintsClock()) {
        self.clock = clock
        self.startedAt = clock.now
    }

    public func hints(for account: String?) -> MeetingHints {
        let key = (account ?? "").lowercased()
        if let hints = byAccount[key] { return hints }
        let hints = MeetingHints(clock: clock, startedAt: startedAt)
        byAccount[key] = hints
        return hints
    }
}
