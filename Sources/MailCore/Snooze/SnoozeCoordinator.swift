import Foundation
import Observation
import os

private let log = Logger(subsystem: "fi.mak8r.mail", category: "snooze")

/// Per-account SnoozeAccount plus the client wake loop (conventions §1: at launch and every 5 min).
/// Main actor; Mac app only in Phase 1.
@MainActor @Observable
public final class SnoozeCoordinator {
    /// Observed by the rows.
    public private(set) var accounts: [String: SnoozeAccount] = [:]
    /// Expired sign-ins: their passes are skipped.
    @ObservationIgnored public var isPaused: @MainActor (String) -> Bool = { _ in false }
    @ObservationIgnored public var onSignInExpired: (@MainActor (String) -> Void)?

    @ObservationIgnored private let policy: WakePolicy
    @ObservationIgnored private let wakerEnabled: Bool
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let launchGrace: Duration
    @ObservationIgnored private let graceSleep: @Sendable (Duration) async throws -> Void

    private struct Runtime {
        weak var session: AccountSession?
        var loop: Task<Void, Never>?
        /// `attach` ran for this session; `prepare` alone only built the holder.
        var attached = false
        /// `prepare` ran: the sorting labels are this coordinator's to keep confirmed after each pass.
        var keepsSortingLabels = false
        /// A sorting-label check that outlasted the launch grace; it reloads the list when it ends.
        var labelCheck: Task<Void, Never>?
    }
    @ObservationIgnored private var runtime: [String: Runtime] = [:]

    /// `launchGrace`: how long `prepare` holds the first load for the sorting-label check (`graceSleep` waits it out).
    public init(policy: WakePolicy = WakePolicy(), wakerEnabled: Bool = true,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                launchGrace: Duration = .seconds(3),
                graceSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.policy = policy
        self.wakerEnabled = wakerEnabled
        self.sleep = sleep
        self.launchGrace = launchGrace
        self.graceSleep = graceSleep
    }

    /// One account's launch, in the order the app needs: the sorting-label check before the store's first load
    /// (`prepare`), the load, then `attach` (launch pass and loop). `isCurrent` false (a sign-in replaced the
    /// session meanwhile): only the store starts. An expired sign-in does not attach.
    public func launch(_ session: AccountSession, isCurrent: @MainActor () -> Bool = { true }) async {
        if isCurrent() { await prepare(session) }
        await session.store.start()
        guard isCurrent(), !session.store.needsSignIn else { return }
        await attach(session)
    }

    /// Lookup only.
    public func account(email: String) -> SnoozeAccount? {
        accounts[email]
    }

    /// Launch: builds the holder (rebuilds it, cancelling the old loop, when the session object changed), runs the
    /// launch pass (awaited), loads label names, then starts the loop. nil when nothing ran: plain FakeGmail,
    /// waker disabled, or this session is already attached.
    @discardableResult
    public func attach(_ session: AccountSession) async -> WakeOutcome? {
        let email = session.email
        if let r = runtime[email], r.session === session, r.attached { return nil }
        guard let account = holder(for: session) else { return nil }
        runtime[email]?.attached = true
        let outcome: WakeOutcome? = wakerEnabled ? await runPass(email: email) : nil
        await account.reloadNames()
        publishMarker(of: account, to: session.store)
        guard wakerEnabled, accounts[email] === account else { return outcome }
        let first = outcome ?? .paused
        let (sleep, policy) = (self.sleep, self.policy)
        runtime[email]?.loop = Task { [weak self] in
            var last = first
            while true {
                do { try await sleep(.seconds(policy.delay(after: last, now: Date()))) } catch { return }
                guard let self, !Task.isCancelled else { return }
                last = await self.runPass(email: email)
            }
        }
        return outcome
    }

    /// The Torkku view's badge comes from labels.get on the marker once its ID is known (gmail-quota §10 P1-4).
    /// Without a marker (deleted in Gmail, say) the badge falls back to the search count.
    private func publishMarker(of account: SnoozeAccount, to store: MailStore) {
        store.countLabelIDs[account.scheme.viewQuery] = account.markerID
    }

    /// Before `store.start()`: builds the holder (as `attach` would, without a pass or a loop) and makes sure the
    /// sorting labels Käsiteltävät excludes exist, so its first load and count ask Gmail a query that can match.
    /// Labels it cannot confirm are left out of the store's queries (`MailStore.setMissingLabels`) and checked
    /// again after each completed wake pass. The first load waits at most `launchGrace`: a slower check (Gmail
    /// rate limiting, a hanging network) leaves both exclusions out for now and reloads the list when it ends.
    public func prepare(_ session: AccountSession) async {
        guard let account = holder(for: session) else { return }
        let (email, store) = (session.email, session.store)
        runtime[email]?.keepsSortingLabels = true
        let check = Task { await account.ensureInboxZeroLabels() }
        if let missing = await result(of: check, within: launchGrace) {
            await store.setMissingLabels(missing)
            return
        }
        await store.setMissingLabels(Set(InboxZero.excludedFromDefault))
        runtime[email]?.labelCheck = Task { [weak self] in
            let missing = await check.value
            guard let self, self.accounts[email] === account else { return }
            await store.setMissingLabels(missing)
        }
    }

    /// The sorting-label check `prepare` left running past the launch grace, if any.
    func labelCheck(email: String) -> Task<Void, Never>? {
        runtime[email]?.labelCheck
    }

    /// The task's value, or nil when `grace` runs out first (the task keeps running).
    private func result<T: Sendable>(of task: Task<T, Never>, within grace: Duration) async -> T? {
        let sleep = graceSleep
        var timer: Task<Void, Never>?
        let value: T? = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let first = FirstValue(continuation)
            Task { @MainActor in first.resume(await task.value) }
            timer = Task { @MainActor in
                do { try await sleep(grace) } catch { return }
                first.resume(nil)
            }
        }
        timer?.cancel()
        return value
    }

    /// The holder for this session object, built (replacing another session's) when needed.
    private func holder(for session: AccountSession) -> SnoozeAccount? {
        let email = session.email
        if let r = runtime[email], r.session === session, let account = accounts[email] { return account }
        detach(email: email)
        guard let account = SnoozeAccount(api: session.api) else { return nil }
        accounts[email] = account
        runtime[email] = Runtime(session: session)
        return account
    }

    /// Cancels the loop; late results are dropped.
    public func detach(email: String) {
        runtime[email]?.loop?.cancel()
        runtime[email] = nil
        accounts[email] = nil
    }

    @discardableResult
    public func runPass(email: String) async -> WakeOutcome {
        guard let account = accounts[email], let entry = runtime[email] else { return .cancelled }
        guard let session = entry.session else {                              // released without detach
            log.notice("wake loop \(email, privacy: .public): session gone, detaching")
            detach(email: email)                                               // ends this loop too
            return .cancelled
        }
        if isPaused(email) { return .paused }
        let outcome: WakeOutcome
        do {
            outcome = WakeOutcome(report: try await account.waker.runOnce())
        } catch {
            outcome = WakeOutcome(error: error)
            if outcome == .failed {
                log.error("wake pass \(email, privacy: .public): \(String(describing: error), privacy: .public)")
            } else if outcome == .rateLimited {
                log.notice("wake pass \(email, privacy: .public): Gmail rate limited, retrying sooner")
            }
        }
        guard accounts[email] === account else { return .cancelled }        // detached or rebuilt meanwhile
        switch outcome {
        case .completed(let woken, let cancelled, _):
            if woken + cancelled > 0 { await session.store.refresh() }        // list + counts; InboxMonitor notices next check
            await account.reloadNames()                                        // the pass refreshed the directory
            publishMarker(of: account, to: session.store)
            // Every pass, not only while some are missing: one may have been deleted in Gmail meanwhile. The pass
            // has just refreshed the directory, so this asks nothing when they exist and recreates a deleted one.
            if runtime[email]?.keepsSortingLabels == true {
                await session.store.setMissingLabels(await account.ensureInboxZeroLabels())
            }
        case .signInExpired:
            onSignInExpired?(email)
        case .skipped, .paused, .offline, .rateLimited, .failed, .cancelled:
            break
        }
        return outcome
    }
}

/// Resumes its continuation with the first value it is given; later ones are dropped.
@MainActor
private final class FirstValue<T: Sendable> {
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
