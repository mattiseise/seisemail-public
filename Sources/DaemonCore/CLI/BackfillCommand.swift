import Foundation
import MailCore

/// Which account a command acts on: `--account` (must have a token file) or the only signed-in one.
public enum AccountChoice {
    public static func resolve(_ explicit: String?, paths: DaemonPaths) throws(UsageError) -> String {
        let accounts = paths.tokenAccounts()
        if let explicit {
            let email = explicit.trimmingCharacters(in: .whitespaces).lowercased()
            guard accounts.contains(email) else {
                throw UsageError("tiliä \(email) ei ole kirjautuneena (mak8r-daemon login \(email))")
            }
            return email
        }
        switch accounts.count {
        case 0: throw UsageError("yhtään tiliä ei ole kirjautuneena (mak8r-daemon login <osoite>)")
        case 1: return accounts[0]
        default: throw UsageError("useita tilejä (\(accounts.joined(separator: ", "))): valitse --account")
        }
    }
}

/// `mak8r-daemon backfill --since … [--account a] [--dry-run]` (design §6.6, §15).
public enum BackfillCommand {
    /// Exact up to `exactPages` × 100 threads, then Gmail's estimate.
    public static let exactPages = 10

    public struct Count: Sendable, Equatable {
        public var threads: Int
        /// false: more than the pages counted; `threads` is Gmail's estimate.
        public var complete: Bool

        public init(threads: Int, complete: Bool) {
            self.threads = threads
            self.complete = complete
        }
    }

    /// Writes `requests/backfill-<key>-<stamp>.json` with `{since, requestedAt}`; the daemon runs it in
    /// the current sorting mode and deletes it when done.
    @discardableResult
    public static func request(since text: String, account: String?, paths: DaemonPaths, now: Date) throws -> URL {
        let email = try AccountChoice.resolve(account, paths: paths)
        guard let since = BackfillRequest.parseSince(text, now: now) else {
            throw UsageError("backfill: --since \(text) ei kelpaa (esimerkiksi 3d tai 2026-10-01; ei tulevaisuuden päivää)")
        }
        return try BackfillRequest(account: email, since: since, requestedAt: now).write(paths: paths)
    }

    /// `--dry-run`: inbox threads since `since` (`threads.list`, 10 units per 100), read only.
    public static func countInbox(api: any GmailAPI, since: Date) async throws -> Count {
        let query = "in:inbox after:\(Int(since.timeIntervalSince1970))"
        var token: String?
        var total = 0
        var estimate = 0
        for _ in 0..<exactPages {
            let page = try await api.listThreads(query: query, pageToken: token, maxResults: SyncEngine.scanPageSize)
            total += page.ids.count
            guard let next = page.nextPageToken else { return Count(threads: total, complete: true) }
            token = next
            estimate = page.estimate
        }
        return Count(threads: max(total, estimate), complete: false)
    }

    public static func dryRunText(count: Count, since: Date, mode: FeatureMode, now: Date) -> String {
        let estimate = BackfillRequest.estimate(threads: count.threads)
        let noun = count.threads == 1 ? "ketju" : "ketjua"
        let amount = count.complete ? "\(count.threads) \(noun)" : "yli \(count.threads) ketjua (Gmailin arvio)"
        let modeText = switch mode {
        case .live: "live: tunnisteet kirjoitetaan"
        case .shadow: "varjotila: päätökset vain lokiin"
        case .off: "pois: daemon ei käsittele pyyntöä ennen kuin lajittelu on päällä"
        }
        return """
        Saapuneissa on \(amount) \(FinnishTime.full(since, now: now)) jälkeen.
        Arvio: enintään \(estimate.units) yksikköä, noin \(estimate.minutes) min lajittelun tahdilla (\(modeText)).
        Aja sama ilman --dry-run, niin daemon käsittelee ne nykyisessä tilassa.
        """
    }
}
