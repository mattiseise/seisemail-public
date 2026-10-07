import DaemonCore
import Foundation
import MailCore

/// `login <email> [--no-browser]` and `login --callback '<url>'` (design §8.2). Run outside the Claude Code
/// sandbox (loopback port). Never revokes and never touches the app's Keychain items.
enum LoginCommand {
    static func login(email: String, noBrowser: Bool, paths: DaemonPaths) async -> Int32 {
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let reader = Task.detached {
            do {
                for try await line in FileHandle.standardInput.bytes.lines { input.yield(line) }
            } catch {}
            input.finish()   // EOF is ignored by the flow
        }
        defer { reader.cancel() }
        try? paths.createDirectories()
        let log = DaemonLog(sink: RotatingFile(url: paths.daemonLog, maxBytes: 5 << 20), mirror: true)
        let browser = !noBrowser
        let env = LoginFlow.Environment(
            paths: paths, oauth: OAuthConfig.fromBundle(), clock: SystemDaemonClock(), transport: URLSessionTransport(),
            makeReceiver: { LoopbackReceiver() },
            present: { url, pasteOnly in
                Output.line(Text.consent(url, pasteOnly: pasteOnly, browser: browser))
                if browser { BrowserOpener.open(url) }
            },
            stdinLines: lines
        )
        do {
            let result = try await LoginFlow.login(email: email, env: env)
            log.notice(result.token.account, "kirjautuminen tallennettu, tokeni \(result.token.fingerprint.short), "
                + "refresh_token_expires_in: \(result.hadExpiresIn ? "kyllä" : "ei")"
                + (result.pasteOnly ? ", liitetty osoite" : ""))
            Output.line("")
            Output.line(Text.loginSaved(result.token, now: Date()))
            Output.line(Text.afterLogin(daemonState(paths)))
            return DaemonExitCode.ok.rawValue
        } catch {
            log.notice(LoginFlow.normalizeEmail(email), "kirjautuminen keskeytyi: \(kind(error)), mitään ei tallennettu")
            Output.error(error.message)
            return error.exitCode
        }
    }

    static func callback(_ text: String, paths: DaemonPaths) async -> Int32 {
        do {
            try await LoginFlow.forwardCallback(text, paths: paths, now: Date()) { url in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = [:]
                configuration.timeoutIntervalForRequest = 10
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                let (_, response) = try await session.data(from: url)
                // The waiting login's receiver answers 200; anything else is not it.
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            }
            Output.line(Text.callbackForwarded)
            return DaemonExitCode.ok.rawValue
        } catch {
            Output.error(error.message)
            return error.exitCode
        }
    }

    /// For the line after a successful login: a fresh `status.json` means a running daemon.
    static func daemonState(_ paths: DaemonPaths) -> Text.DaemonState {
        if let status = StatusFile.read(paths.status), status.health(now: Date()) != .notRunning { return .running }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fi.seise.mail.daemon.plist")
        return FileManager.default.fileExists(atPath: plist.path) ? .installedNotRunning : .notInstalled
    }

    /// The error's kind for the log (no addresses beyond the account, no URLs).
    static func kind(_ error: LoginError) -> String {
        switch error {
        case .oauthMissing: "oauthMissing"
        case .invalidEmail: "invalidEmail"
        case .wrongAccount: "wrongAccount"
        case .denied(let what): "denied(\(what))"
        case .timeout: "timeout"
        case .unavailable: "unavailable"
        case .noPendingLogin: "noPendingLogin"
        case .pendingExpired: "pendingExpired"
        case .invalidCallback: "invalidCallback"
        case .forwardFailed: "forwardFailed"
        case .pasteOnlyLogin: "pasteOnlyLogin"
        case .anotherLoginPending: "anotherLoginPending"
        }
    }
}
