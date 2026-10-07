import DaemonCore
import Foundation
import MailCore

/// Commands about one signed-in account: `logout`, `explain`, `backfill`, `debug …`.
enum AccountCommands {
    static func logout(_ raw: String, paths: DaemonPaths) -> Int32 {
        guard let email = LoginFlow.normalizeEmail(raw) else {
            Output.error(LoginError.invalidEmail(raw).message)
            return DaemonExitCode.usage.rawValue
        }
        let url = paths.token(email)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Output.line("Tili \(email) ei ole kirjautuneena daemoniin, joten mitään ei poistettu.")
            return DaemonExitCode.ok.rawValue
        }
        do {
            try FileTokenStore.delete(url)
        } catch {
            Output.error("Tokenia ei voi poistaa: \(error)")
            return DaemonExitCode.unavailable.rawValue
        }
        Output.line("Tokeni poistettu: daemon lopettaa tilin \(email) käsittelyn minuutin kuluessa.")
        Output.line("Kirjautumista ei peruttu Googlen puolella, koska se kirjaisi ulos myös sovellukset. Tilatiedosto säilyi.")
        return DaemonExitCode.ok.rawValue
    }

    /// `explain <threadId>`: one fresh read through a shadow gate (41 units, the CLI's own quota stack).
    static func explain(_ threadID: String, account: String?, paths: DaemonPaths) async -> Int32 {
        let email: String
        do {
            email = try AccountChoice.resolve(account, paths: paths)
        } catch {
            return usage(error)
        }
        guard let oauth = OAuthConfig.fromBundle() else { return oauthMissing() }
        let (config, rules, problems) = await ConfigStore(paths: paths).current()
        let stack = shadowStack(email: email, oauth: oauth, paths: paths, config: config)
        do {
            let thread = try await stack.sortAPI.threadHeaders(id: threadID, headers: DaemonHeaders.thread)
            let snapshot = try await stack.sortDirectory.snapshot(knowing: thread.labelIDs)
            let state = StateStore.peek(paths.state(email))
            for problem in problems { Output.line("Asetusvirhe (käytössä viimeisin kelvollinen): \(problem)") }
            Output.line(ExplainReport.render(thread: thread, labels: snapshot, rules: rules, sent: state?.sent ?? SentCache(),
                                             me: Set(state?.me ?? [email]), now: Date()))
            if state == nil {
                Output.line("Huom: tilatiedostoa ei ole, joten lähetettyjen välimuisti on tyhjä (sääntö ”ihmiset” ei voi osua).")
            } else if state?.sentBackfill.phase != .done {
                Output.line("Huom: lähetettyjen välimuisti rakennetaan vielä (sääntö ”ihmiset” voi jäädä osumatta).")
            }
            Output.line("Lajittelun tila: \(config.sorting.rawValue)")
            return DaemonExitCode.ok.rawValue
        } catch {
            return apiFailure(error, email: email, what: "ketju \(threadID)")
        }
    }

    static func backfill(since: String, account: String?, dryRun: Bool, paths: DaemonPaths) async -> Int32 {
        let now = Date()
        let (config, _, _) = await ConfigStore(paths: paths).current()
        guard dryRun else {
            do {
                let url = try BackfillCommand.request(since: since, account: account, paths: paths, now: now)
                Output.line("Pyyntö tallennettu (\(url.lastPathComponent)).")
                Output.line(config.sorting == .off
                    ? "Lajittelu on pois päältä: pyyntö odottaa, kunnes lajittelun tila on shadow tai live."
                    : "Daemon käy Saapuneet-kansion ketjut läpi tilassa \(config.sorting.rawValue) seuraavalla kierroksella. Edistymisen näkee komennolla mak8r-daemon status.")
                return DaemonExitCode.ok.rawValue
            } catch let error as UsageError {
                return usage(error)
            } catch {
                Output.error("Pyyntöä ei voi tallentaa: \(error)")
                return DaemonExitCode.unavailable.rawValue
            }
        }
        let email: String
        do {
            email = try AccountChoice.resolve(account, paths: paths)
        } catch {
            return usage(error)
        }
        guard let start = BackfillRequest.parseSince(since, now: now) else {
            return usage(UsageError("backfill: --since \(since) ei kelpaa (esimerkiksi 3d tai 2026-10-01; ei tulevaisuuden päivää)"))
        }
        guard let oauth = OAuthConfig.fromBundle() else { return oauthMissing() }
        let stack = shadowStack(email: email, oauth: oauth, paths: paths, config: config)
        do {
            let count = try await BackfillCommand.countInbox(api: stack.sortAPI, since: start)
            Output.line(BackfillCommand.dryRunText(count: count, since: start, mode: config.sorting, now: now))
            return DaemonExitCode.ok.rawValue
        } catch {
            return apiFailure(error, email: email, what: "Saapuneet")
        }
    }

    static func invalidateToken(_ raw: String, paths: DaemonPaths) -> Int32 {
        let email: String
        do {
            email = try AccountChoice.resolve(raw, paths: paths)
        } catch {
            return usage(error)
        }
        do {
            let token = try FileTokenStore.invalidate(at: paths.token(email))
            Output.line("Tokeni korvattu kelvottomalla (sormenjälki \(token.fingerprint.short)).")
            Output.line("Daemon huomaa sen minuutin kuluessa: mak8r-daemon status näyttää KIRJAUDU UUDELLEEN.")
            Output.line("Palauta kirjautumalla: mak8r-daemon login \(email)")
            return DaemonExitCode.ok.rawValue
        } catch {
            Output.error("Tokenia ei voi korvata: \(error)")
            return DaemonExitCode.invalidData.rawValue
        }
    }

    /// `debug note-now`: through the running daemon (a request file it picks up within a minute), or here
    /// when the daemon is not running (holding its lock, so the two never write the state at once).
    static func noteNow(_ raw: String, paths: DaemonPaths) async -> Int32 {
        let email: String
        do {
            email = try AccountChoice.resolve(raw, paths: paths)
        } catch {
            return usage(error)
        }
        guard let lock = try? InstanceLock(paths.lock) else {
            do {
                try NoteRequest(account: email, requestedAt: Date()).write(paths: paths)
            } catch {
                Output.error("Pyyntöä ei voi tallentaa: \(error)")
                return DaemonExitCode.unavailable.rawValue
            }
            Output.line("Pyyntö annettu daemonille: muistutus tulee Saapuneisiin minuutin kuluessa.")
            return DaemonExitCode.ok.rawValue
        }
        defer { lock.release() }
        guard let oauth = OAuthConfig.fromBundle() else { return oauthMissing() }
        let foreground = Foreground(paths: paths, oauth: oauth, echo: false)
        let runner = foreground.runner(email)
        do {
            let id = try await runner.insertNoteNow()
            await runner.flush()
            Output.line("Muistutus lisätty Saapuneisiin (\(id)). Se arkistoituu seuraavan kirjautumisen jälkeen.")
            return DaemonExitCode.ok.rawValue
        } catch {
            return apiFailure(error, email: email, what: "muistutus")
        }
    }

    // MARK: - Helpers

    /// The account's stack with both gates in shadow: reads pass through, writes are refused into the log.
    static func shadowStack(email: String, oauth: OAuthConfig, paths: DaemonPaths, config: DaemonConfig) -> AccountStack {
        var shadow = config
        shadow.wake = .shadow
        shadow.sorting = .shadow
        return AccountStack.make(email: email, oauth: oauth, paths: paths, config: shadow) { write in
            Output.error("VARJO (ei kirjoitettu): \(write.summary)")
        }
    }

    static func usage(_ error: UsageError) -> Int32 {
        Output.error("mak8r-daemon: \(error.message)")
        return DaemonExitCode.usage.rawValue
    }

    static func oauthMissing() -> Int32 {
        Output.error(Text.oauthMissing())
        return DaemonExitCode.unavailable.rawValue
    }

    static func apiFailure(_ error: any Error, email: String, what: String) -> Int32 {
        if WakeOutcome(error: error) == .signInExpired {
            Output.error("Kirjautuminen ei kelpaa (vanhentunut tai peruttu). Kirjaudu uudelleen: mak8r-daemon login \(email)")
            return DaemonExitCode.unavailable.rawValue
        }
        if GmailFailure.isNotFound(error) {
            Output.error("Ei löydy: \(what).")
            return DaemonExitCode.invalidData.rawValue
        }
        if (error as? GmailError) == .offline {
            Output.error("Ei verkkoyhteyttä Gmailiin.")
            return DaemonExitCode.unavailable.rawValue
        }
        Output.error("Gmail-virhe (\(what)): \(Sanitize.line(String(describing: error)))")
        return DaemonExitCode.unavailable.rawValue
    }
}
