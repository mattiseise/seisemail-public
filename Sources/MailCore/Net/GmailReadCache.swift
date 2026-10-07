import Foundation

/// Thread bodies keyed by request, valid while the thread's `historyId` from the latest list is
/// unchanged. Pure state; `GmailReadCacheTransport` drives it.
///
/// Safe because every caller lists right before it fetches rows (`MailStore.fetchSummaries`,
/// `InboxMonitor.fetch`), so a hit is exactly the state that caller's own list reported.
struct GmailReadCache: Sendable {
    struct Policy: Sendable {
        var capacity = 1_000
        /// How long a list observation vouches for a body.
        var listFreshness: Duration = .seconds(120)
        var maxAge: Duration = .seconds(3_600)
        /// `format` values whose bodies are cached: list rows, and the snooze waker's label scan.
        var formats: Set<String> = ["metadata", "minimal"]
    }

    private struct Entry: Sendable {
        var threadID: String
        /// `messages[].id` in the body, so a `messages/*` write can find its thread.
        var messageIDs: Set<String>
        var body: Data
        var historyID: UInt64
        var storedAt: Duration
        var lastUsed: UInt64
    }

    private struct Observation: Sendable {
        var historyID: UInt64
        var at: Duration
    }

    private struct Write: Sendable {
        var seq: UInt64
        var at: Duration
    }

    let policy: Policy
    private var entries: [String: Entry] = [:]
    private var observations: [String: Observation] = [:]
    /// `writeSeq` at each thread's latest write; responses that started earlier are not kept.
    private var lastWrite: [String: Write] = [:]
    private var lastWriteAll: UInt64 = 0
    private var lastPrune: Duration = .zero
    private(set) var writeSeq: UInt64 = 0
    private var useCounter: UInt64 = 0
    private var hits = 0
    private var misses = 0

    init(policy: Policy) {
        self.policy = policy
    }

    var stats: (hits: Int, misses: Int) { (hits, misses) }
    var count: Int { entries.count }
    /// Per-thread bookkeeping besides the bodies, for tests of its bound.
    var trackedThreads: (observations: Int, writes: Int) { (observations.count, lastWrite.count) }

    mutating func lookup(threadID: String, key: String, now: Duration) -> Data? {
        guard var entry = entries[key] else {
            misses += 1
            return nil
        }
        if now - entry.storedAt > policy.maxAge {
            entries[key] = nil
            misses += 1
            return nil
        }
        guard let seen = observations[threadID], seen.historyID == entry.historyID, now - seen.at <= policy.listFreshness else {
            misses += 1
            return nil
        }
        useCounter += 1
        entry.lastUsed = useCounter
        entries[key] = entry
        hits += 1
        return entry.body
    }

    /// Keeps a 2xx thread body that has a top-level `historyId`, unless the thread was written
    /// after the request started (`startedAt` is `writeSeq` at that time).
    mutating func store(threadID: String, key: String, body: Data, startedAt: UInt64, now: Duration) {
        guard !writtenSince(startedAt, threadID: threadID),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let historyID = Self.uint64(root["historyId"]) else { return }
        let messageIDs = Set((root["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        useCounter += 1
        entries[key] = Entry(threadID: threadID, messageIDs: messageIDs, body: body, historyID: historyID,
                             storedAt: now, lastUsed: useCounter)
        while entries.count > policy.capacity, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries[oldest] = nil
        }
    }

    /// Records `threads[].historyId` from a 2xx list body. A lower `historyId` than already seen
    /// is ignored, so a late, stale list can't roll an observation back.
    mutating func observeList(_ body: Data, startedAt: UInt64, now: Duration) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let threads = root["threads"] as? [[String: Any]] else { return }
        for thread in threads {
            guard let id = thread["id"] as? String, let historyID = Self.uint64(thread["historyId"]) else { continue }
            guard !writtenSince(startedAt, threadID: id) else { continue }
            if let seen = observations[id], seen.historyID > historyID { continue }
            observations[id] = Observation(historyID: historyID, at: now)
        }
        prune(now: now)
    }

    /// Forgets observations and writes older than `maxAge`: no request runs that long (90 s of
    /// queueing plus a 300 s timeout), so they can no longer vouch for a body or guard against one.
    private mutating func prune(now: Duration) {
        guard now - lastPrune >= .seconds(60) else { return }
        lastPrune = now
        observations = observations.filter { now - $0.value.at <= policy.maxAge }
        lastWrite = lastWrite.filter { now - $0.value.at <= policy.maxAge }
    }

    mutating func invalidate(threadID: String, now: Duration) {
        invalidate(threadIDs: [threadID], now: now)
    }

    mutating func invalidate(threadIDs: Set<String>, now: Duration) {
        writeSeq += 1
        for id in threadIDs {
            lastWrite[id] = Write(seq: writeSeq, at: now)
            observations[id] = nil
        }
        entries = entries.filter { !threadIDs.contains($0.value.threadID) }
    }

    /// The threads whose stored bodies hold these messages; nil when any id is unknown here.
    func threads(owning messageIDs: [String]) -> Set<String>? {
        guard !messageIDs.isEmpty else { return nil }
        var owner: [String: String] = [:]
        for entry in entries.values {
            for id in entry.messageIDs { owner[id] = entry.threadID }
        }
        var threads: Set<String> = []
        for id in messageIDs {
            guard let thread = owner[id] else { return nil }
            threads.insert(thread)
        }
        return threads
    }

    mutating func invalidateAll() {
        writeSeq += 1
        lastWriteAll = writeSeq
        lastWrite = [:]
        observations = [:]
        entries = [:]
    }

    private func writtenSince(_ startedAt: UInt64, threadID: String) -> Bool {
        lastWriteAll > startedAt || (lastWrite[threadID]?.seq ?? 0) > startedAt
    }

    static func historyID(in body: Data) -> UInt64? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return uint64(root["historyId"])
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let s as String: UInt64(s)
        case let n as NSNumber: n.uint64Value
        default: nil
        }
    }
}
