import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §8.3 and D6/D7: expiry notes, `invalid_grant` → `needsLogin` with state kept, the token fingerprint
/// rebuild (`renewed` / `resumed`) and transient token-endpoint failures.
///
/// The default token expires Monday 12.10.2026 at 9.12 Helsinki (06:12Z); the clock starts Monday 5.10. at 12.00.30.
@Suite struct AuthLifecycleTests {
    let env: DaemonEnv
    let expires = D(1_791_785_520)

    init() throws {
        env = try DaemonEnv()
        try env.writeToken("r1")
        try env.setConfig(sorting: .live)
    }

    var fake: SyncFakeGmail { env.fake }

    func phase(_ runner: AccountRunner) async -> AccountPhase { await runner.phase }

    func loginReason(_ runner: AccountRunner) async -> LoginReason? {
        if case .needsLogin(_, let reason) = await phase(runner) { return reason }
        return nil
    }

    /// Both loops once.
    func minute(_ runner: AccountRunner) async {
        _ = await runner.wakeTick()
        _ = await runner.syncTick()
    }

    // MARK: invalid_grant

    @Test func invalidGrantMidSyncPausesWithStateKept() async throws {
        try env.seedState(watermark: "1000")
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()                                       // running
        env.newsletter("t2")
        fake.update { $0.failAll = AuthError.invalidGrant }
        _ = await runner.syncTick()
        #expect(await loginReason(runner) == .expired)
        #expect(env.storedAuth?["status"] as? String == "needsLogin")
        #expect(env.storedAuth?["since"] is String)
        #expect(env.notifier.needsLogin == [false])
        #expect(fake.modifies(of: "t2").isEmpty)
        let starts = fake.historyStarts

        let attempts = fake.attempts
        for _ in 0..<3 {
            env.clock.advance(by: 60)
            await minute(runner)
        }
        #expect(fake.attempts == attempts)                                // both loops idle: no API calls
        #expect(env.notifier.needsLogin == [false])
        #expect(fake.historyStarts == starts)
        #expect(FileManager.default.fileExists(atPath: env.paths.token(env.email).path))   // the token file stays
    }

    @Test func invalidGrantFromTheWakeLoopPausesToo() async throws {
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        fake.update { $0.failAll = AuthError.invalidGrant }
        _ = await runner.wakeTick()
        #expect(await loginReason(runner) == .expired)
        #expect(env.notifier.needsLogin == [false])
    }

    @Test func notSignedInCountsAsExpired() async throws {
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        fake.update { $0.failAll = AuthError.notSignedIn }
        _ = await runner.syncTick()
        #expect(await loginReason(runner) == .expired)
    }

    @Test func watermarkIsKeptWhilePaused() async throws {
        try env.seedState(watermark: "1000")
        fake.update { $0.failAll = AuthError.invalidGrant }
        let runner = env.runner()
        _ = await runner.syncTick()
        env.clock.advance(by: 20 * 60)
        await minute(runner)
        #expect(env.storedWatermark == "1000")
        #expect((env.state()?["sentBackfill"] as? [String: Any])?["phase"] as? String == "done")
    }

    @Test func restartDoesNotRepeatTheNotice() async throws {
        try env.seedState(watermark: "1000")
        fake.update { $0.failAll = AuthError.invalidGrant }
        _ = await env.runner().syncTick()
        #expect(env.notifier.needsLogin == [false])
        env.clock.advance(by: 120)
        let second = env.runner()                                         // launchd restarted the process
        await minute(second)
        #expect(await loginReason(second) == .expired)
        #expect(env.notifier.needsLogin == [false])
    }

    @Test func dailyReminderAtNineHelsinkiOnly() async throws {
        try env.seedState(watermark: "1000")
        fake.update { $0.failAll = AuthError.invalidGrant }
        let runner = env.runner()
        _ = await runner.syncTick()                                       // Mon 12.00.30: the first notice
        env.clock.advance(to: D(1_791_201_600))                           // Mon 15.00
        await minute(runner)
        env.clock.advance(to: D(1_791_266_340))                           // Tue 08.59
        await minute(runner)
        #expect(env.notifier.needsLogin == [false])
        env.clock.advance(to: D(1_791_266_430))                           // Tue 09.00.30
        await minute(runner)
        #expect(env.notifier.needsLogin == [false, true])
        env.clock.advance(to: D(1_791_288_000))                           // Tue 15.00
        await minute(runner)
        #expect(env.notifier.needsLogin == [false, true])
        env.clock.advance(to: D(1_791_352_860))                           // Wed 09.01
        await minute(runner)
        #expect(env.notifier.needsLogin == [false, true, true])
    }

    @Test func reminderThrottleSurvivesARestart() async throws {
        try env.seedState(watermark: "1000")
        fake.update { $0.failAll = AuthError.invalidGrant }
        _ = await env.runner().syncTick()
        env.clock.advance(to: D(1_791_266_430))                           // Tue 09.00.30
        await minute(env.runner())
        #expect(env.notifier.needsLogin == [false, true])
        env.clock.advance(by: 120)
        await minute(env.runner())                                        // restarted at 09.02.30
        #expect(env.notifier.needsLogin == [false, true])
    }

    // MARK: Token file problems at start

    @Test func missingTokenNeedsLoginWithoutAPICalls() async throws {
        try FileTokenStore.delete(env.paths.token(env.email))
        let runner = env.runner()
        await minute(runner)
        #expect(await loginReason(runner) == .tokenMissing)
        #expect(fake.attempts == 0)
    }

    @Test func unreadableTokenNeedsLogin() async throws {
        try Data("garbage".utf8).write(to: env.paths.token(env.email))
        let runner = env.runner()
        await minute(runner)
        #expect(await loginReason(runner) == .tokenUnreadable)
        #expect(fake.attempts == 0)
    }

    @Test func changedOAuthClientNeedsLogin() async throws {
        try env.writeToken("r1", clientID: "other-client.apps.googleusercontent.com")
        let runner = env.runner()
        await minute(runner)
        #expect(await loginReason(runner) == .clientChanged)
        #expect(fake.attempts == 0)
    }

    @Test func loginAfterAMissingTokenStartsTheAccount() async throws {
        try FileTokenStore.delete(env.paths.token(env.email))
        let runner = env.runner()
        await minute(runner)
        #expect(await loginReason(runner) == .tokenMissing)
        try env.writeToken("r2", consentedAt: env.clock.now())
        env.clock.advance(by: 30)
        await minute(runner)
        await minute(runner)
        let now = await phase(runner)
        #expect(now == .running || now == .backfillingSent)
        #expect(fake.calls.contains("profile"))                           // bootstrapped
    }

    // MARK: Fingerprint changes (D6)

    @Test func newLoginWhileRunningIsRenewedAndArchivesTheNotes() async throws {
        try env.seedState(watermark: "1000", warned: [24], noteThreadIDs: ["note-1"])
        fake.deliver("note-1", from: env.email, subject: "Mak8r-daemon: kirjaudu uudelleen", headers: ["X-Mak8r-Daemon": "1"],
                     inHistory: false)
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(env.builtStacks.count == 1)
        try env.writeToken("r2", consentedAt: env.clock.now())
        env.clock.advance(by: 60)
        _ = await runner.syncTick()
        #expect(env.builtStacks.count == 2)                               // the stack was rebuilt
        #expect(env.notifier.renewed == 1)
        #expect(env.notifier.resumedAfter.isEmpty)
        #expect(fake.modifies(of: "note-1") == ["modify note-1 + -INBOX"])
        #expect(!fake.labelNames(of: "note-1").contains("INBOX"))
        let auth = try #require(env.storedAuth)
        #expect(auth["warned"] as? [Int] == [])
        #expect(auth["noteThreadIDs"] as? [String] == [])
        #expect(auth["fingerprint"] as? String == fingerprint("r2"))
        #expect(await phase(runner) == .running)
    }

    @Test func notesAreArchivedEvenInShadowSorting() async throws {
        try env.setConfig(sorting: .shadow)
        try env.seedState(watermark: "1000", warned: [24], noteThreadIDs: ["note-1"])
        fake.deliver("note-1", from: env.email, headers: ["X-Mak8r-Daemon": "1"], inHistory: false)
        let runner = env.runner()
        _ = await runner.syncTick()
        try env.writeToken("r2", consentedAt: env.clock.now())
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "note-1") == ["modify note-1 + -INBOX"])  // noteAPI is always live
    }

    @Test func newLoginInNeedsLoginResumesAndReplaysExactly() async throws {
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        fake.update { $0.failAll = AuthError.invalidGrant }
        _ = await runner.syncTick()
        #expect(await loginReason(runner) == .expired)

        env.clock.advance(by: 2 * 3_600)
        env.newsletter("t1")                                              // arrives during the pause
        await minute(runner)
        fake.update { $0.failAll = nil }
        try env.writeToken("r2", consentedAt: env.clock.now())
        env.clock.advance(by: 30)
        await tick(runner, limit: 3) { fake.modifies(of: "t1").count >= 1 }
        #expect(await phase(runner) == .running)
        #expect(env.notifier.resumedAfter.count == 1)
        #expect((env.notifier.resumedAfter.first ?? 0) >= 2 * 3_600)
        #expect(env.notifier.renewed == 0)
        #expect(fake.historyStarts.first == "1000")                       // replay from the stored watermark
        #expect(fake.modifies(of: "t1").count == 1)
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "t1").count == 1)
        #expect(env.storedAuth?["status"] as? String == "ok")
    }

    /// A login made while no runner watched (logout + login, disabled account, daemon booted out): the new
    /// runner resumes for good, and a restart keeps it running.
    @Test func persistedNeedsLoginWithANewTokenAtStartResumesForGood() async throws {
        try env.seedState(watermark: "1000", authStatus: "needsLogin", since: env.clock.now().addingTimeInterval(-3_600),
                          noteThreadIDs: ["note-1"])
        fake.deliver("note-1", from: env.email, headers: ["X-Mak8r-Daemon": "1"], inHistory: false)
        try env.writeToken("r2", consentedAt: env.clock.now())
        let first = env.runner()
        await minute(first)
        #expect(await phase(first) == .running)
        #expect(env.notifier.resumedAfter.count == 1)
        #expect(env.notifier.renewed == 0)
        #expect(env.storedAuth?["status"] as? String == "ok")
        #expect(env.storedAuth?["fingerprint"] as? String == fingerprint("r2"))
        #expect(fake.modifies(of: "note-1") == ["modify note-1 + -INBOX"])
        await first.flush()

        let attempts = fake.attempts
        let second = env.runner()                                         // reboot / daemon-install
        env.clock.advance(by: 60)
        await minute(second)
        #expect(await phase(second) == .running)
        #expect(fake.attempts > attempts)
        #expect(env.notifier.resumedAfter.count == 1)
    }

    @Test func invalidGrantAfterAResumeAtStartNotifiesAtOnce() async throws {
        try env.seedState(watermark: "1000", authStatus: "needsLogin", since: env.clock.now().addingTimeInterval(-3_600))
        try env.writeToken("r2", consentedAt: env.clock.now())
        let runner = env.runner()
        await minute(runner)
        #expect(await phase(runner) == .running)
        env.clock.advance(by: 3_600)
        fake.update { $0.failAll = AuthError.invalidGrant }
        _ = await runner.syncTick()
        #expect(env.notifier.needsLogin == [false])
        if case .needsLogin(let since, _) = await phase(runner) {
            #expect(since == env.clock.now())                              // a new outage, not the old one
        } else {
            Issue.record("not in needsLogin")
        }
    }

    /// §22 step 24: `debug invalidate-token` is not a login. No `renewed`, notes and warnings kept, and the
    /// next call meets invalid_grant.
    @Test func invalidateTokenDrillGoesStraightToNeedsLogin() async throws {
        try env.seedState(watermark: "1000", warned: [24], noteThreadIDs: ["note-1"])
        fake.deliver("note-1", from: env.email, headers: ["X-Mak8r-Daemon": "1"], inHistory: false)
        let runner = env.runner()
        _ = await runner.syncTick()
        try FileTokenStore.invalidate(at: env.paths.token(env.email))
        fake.update { $0.failAll = AuthError.invalidGrant }               // Google's answer to the garbage token
        env.clock.advance(by: 60)
        await minute(runner)
        #expect(env.notifier.renewed == 0)
        #expect(await loginReason(runner) == .expired)
        #expect(env.notifier.needsLogin == [false])
        #expect(env.storedAuth?["noteThreadIDs"] as? [String] == ["note-1"])
        #expect(env.storedAuth?["warned"] as? [Int] == [24])
        #expect(!env.logText.contains("kirjautuminen uusittu"))
        #expect(!env.logText.contains("arkistointi epäonnistui"))
    }

    @Test func wakesDueDuringThePauseFireOnTheFirstTick() async throws {
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        fake.update { $0.failAll = AuthError.invalidGrant }
        _ = await runner.wakeTick()
        fake.labels.addSnoozedThread("snoozed", wake: "20261005T1000Z")    // due an hour into the pause
        env.clock.advance(by: 2 * 3_600)
        await minute(runner)
        #expect(fake.modifies(of: "snoozed").isEmpty)
        fake.update { $0.failAll = nil }
        try env.writeToken("r2", consentedAt: env.clock.now())
        env.clock.advance(by: 30)
        await minute(runner)
        #expect(fake.modifies(of: "snoozed").count == 1)
    }

    // MARK: Expiry notes (T−24 h, T−3 h)

    @Test(arguments: [FeatureMode.off, .shadow, .live])
    func notesAtTMinus24AndTMinus3OnceEach(_ sorting: FeatureMode) async throws {
        env.clock.set(expires.addingTimeInterval(-23 * 3_600))
        try env.setConfig(sorting: sorting)
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(fake.inserted.count == 1)
        #expect(env.notifier.expiresSoonHours == [24])
        #expect(env.storedAuth?["warned"] as? [Int] == [24])
        #expect((env.storedAuth?["noteThreadIDs"] as? [String])?.count == 1)
        _ = await runner.syncTick()
        env.clock.advance(by: 3_600)
        _ = await runner.syncTick()
        #expect(fake.inserted.count == 1)

        env.clock.advance(to: expires.addingTimeInterval(-2 * 3_600))
        _ = await runner.syncTick()
        #expect(fake.inserted.count == 2)
        #expect(env.notifier.expiresSoonHours == [24, 3])
        #expect(env.storedAuth?["warned"] as? [Int] == [24, 3])
        #expect((env.storedAuth?["noteThreadIDs"] as? [String])?.count == 2)
        _ = await runner.syncTick()
        #expect(fake.inserted.count == 2)
        #expect(!fake.writes.contains { $0.hasPrefix("modify note-") })   // own notes are never sorted
    }

    @Test func anInsertedNoteIsArchivedAfterTheNextLogin() async throws {
        env.clock.set(expires.addingTimeInterval(-23 * 3_600))
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(env.storedAuth?["noteThreadIDs"] as? [String] == ["note-1"])   // the thread, not the message
        try env.writeToken("r2", consentedAt: env.clock.now())
        env.clock.advance(by: 60)
        _ = await runner.syncTick()
        #expect(fake.modifies(of: "note-1") == ["modify note-1 + -INBOX"])
        #expect(!fake.labelNames(of: "note-1").contains("INBOX"))
    }

    @Test func bothNotesWhenTheDaemonWasDownAtTMinus24() async throws {
        env.clock.set(expires.addingTimeInterval(-2 * 3_600))
        try env.seedState(watermark: "1000")
        _ = await env.runner().syncTick()
        // Writing `warned` first, both thresholds are due now: one note, the nearer one.
        #expect(fake.inserted.count == 1)
        #expect(env.notifier.expiresSoonHours == [3])
        #expect(Set(env.storedAuth?["warned"] as? [Int] ?? []) == [24, 3])
    }

    /// Google rotating the refresh token is not a new login: the warnings already sent stay sent.
    @Test func refreshTokenRotationKeepsTheWarnings() async throws {
        env.clock.set(expires.addingTimeInterval(-23 * 3_600))
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        _ = await runner.syncTick()
        #expect(fake.inserted.count == 1)
        let stack = try #require(env.latestStack)
        let loaded = try #require(stack.tokens.loadedToken)
        stack.tokens.save(TokenSet(accessToken: "a2", refreshToken: "r1-rotated", expiresAt: env.clock.now().addingTimeInterval(3_600),
                                   consentedAt: loaded.consentedAt, refreshTokenExpiresAt: loaded.refreshTokenExpiresAt))
        #expect(stack.tokens.loadedFingerprint?.short == fingerprint("r1-rotated"))
        env.clock.advance(by: 3_600)
        _ = await runner.syncTick()
        _ = await runner.syncTick()
        #expect(fake.inserted.count == 1)
        #expect(env.notifier.expiresSoonHours == [24])
        #expect(env.storedAuth?["warned"] as? [Int] == [24])
        #expect(env.storedAuth?["fingerprint"] as? String == fingerprint("r1-rotated"))
        #expect(env.notifier.renewed == 0)
    }

    @Test func noNoteBeforeTMinus24() async throws {
        env.clock.set(expires.addingTimeInterval(-25 * 3_600))
        try env.seedState(watermark: "1000")
        _ = await env.runner().syncTick()
        #expect(fake.inserted.isEmpty)
        #expect(env.notifier.expiresSoonHours.isEmpty)
    }

    @Test func crashBetweenWarnedAndInsertLosesTheNoteButNeverDuplicates() async throws {
        env.clock.set(expires.addingTimeInterval(-23 * 3_600))
        try env.seedState(watermark: "1000", warned: [24])                // saved, then the process died
        _ = await env.runner().syncTick()
        #expect(fake.inserted.isEmpty)
    }

    @Test func noteContent() async throws {
        try env.writeToken("1//refresh-SECRET-token")
        env.clock.set(expires.addingTimeInterval(-23 * 3_600))
        try env.seedState(watermark: "1000")
        _ = await env.runner().syncTick()
        let note = try #require(fake.inserted.first)
        #expect(note.labelIDs.sorted() == ["INBOX", "UNREAD"])
        let headers = SyncFakeGmail.parseHeaders(note.raw)
        #expect(headers["x-mak8r-daemon"] == ["1"])
        #expect(headers["auto-submitted"] == ["auto-generated"])
        #expect(headers["from"]?.first?.contains(env.email) == true)
        #expect(headers["to"]?.first?.contains(env.email) == true)
        #expect(headers["subject"] == ["Mak8r-daemon: kirjaudu uudelleen ennen ma 12.10. klo 9.12"])
        let contentType = headers["content-type"]?.first?.lowercased() ?? ""
        #expect(contentType.contains("text/plain") && contentType.contains("utf-8"))
        let body = noteBody(note.raw, encoding: headers["content-transfer-encoding"]?.first)
        #expect(body.contains("12.10.2026 klo 9.12"))
        #expect(body.contains("mak8r-daemon login \(env.email)"))
        #expect(body.contains("--no-browser"))
        #expect(body.contains("login --callback"))
        let text = String(decoding: note.raw, as: UTF8.self)
        #expect(!text.contains("SECRET"))
        #expect(!text.contains("refresh"))
    }

    func noteBody(_ raw: Data, encoding: String?) -> String {
        let body = SyncFakeGmail.body(raw)
        if encoding?.lowercased() == "base64" {
            return String(decoding: Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data(), as: UTF8.self)
        }
        return body
    }

    @Test func notesUseTheRefreshTokenExpiryWhenGoogleSendsIt() async throws {
        let dies = D(1_791_500_000)
        try env.writeToken("r1", refreshTokenExpiresAt: dies)
        env.clock.set(dies.addingTimeInterval(-20 * 3_600))
        try env.seedState(watermark: "1000")
        _ = await env.runner().syncTick()
        #expect(fake.inserted.count == 1)
    }

    @Test func notesAreNotSentWhenSwitchedOff() async throws {
        try env.setConfig(sorting: .live) { $0.notify.inboxNote = false }
        env.clock.set(expires.addingTimeInterval(-23 * 3_600))
        try env.seedState(watermark: "1000")
        _ = await env.runner().syncTick()
        #expect(fake.inserted.isEmpty)
        #expect(env.notifier.expiresSoonHours == [24])                    // the other channels still hear it
    }

    @Test func noProactiveNeedsLoginAtTheEstimatedExpiry() async throws {
        env.clock.set(expires.addingTimeInterval(600))                    // the estimate has passed
        try env.seedState(watermark: "1000", warned: [24, 3])
        let runner = env.runner()
        await minute(runner)
        #expect(await phase(runner) == .running)
        #expect(env.notifier.needsLogin.isEmpty)
    }

    // MARK: Transient token-endpoint failures

    @Test func badResponseStreakNeverNeedsLoginAndReportsOnceAfterAnHour() async throws {
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        fake.update { $0.failAll = AuthError.badResponse }
        await minute(runner)
        env.clock.advance(by: 30 * 60)
        await minute(runner)
        #expect(env.notifier.persistentErrorKinds.isEmpty)
        env.clock.advance(by: 31 * 60)
        await minute(runner)
        #expect(env.notifier.persistentErrorKinds == ["tokenEndpoint"])
        env.clock.advance(by: 60 * 60)
        await minute(runner)
        #expect(env.notifier.persistentErrorKinds == ["tokenEndpoint"])   // once per 24 h
        #expect(await loginReason(runner) == nil)
        #expect(env.notifier.needsLogin.isEmpty)
        #expect(env.storedWatermark == "1000")

        fake.update { $0.failAll = nil }
        env.clock.advance(by: 60)
        _ = await runner.syncTick()
        #expect(fake.historyStarts == ["1000"])                           // retried each tick, resumes by itself
    }
}
