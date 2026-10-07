import DaemonCore
import Foundation

/// `mak8r-daemon` (design §15): argv dispatch. Everything testable lives in DaemonCore; this target is the
/// glue for argv, signals, the notify hook's `Process` and `/usr/bin/open`.
@main
enum DaemonMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let code: Int32
        do {
            code = await dispatch(try DaemonCommand.parse(arguments))
        } catch {
            Output.error("mak8r-daemon: \(error.message)")
            Output.error(Text.helpHint)
            code = DaemonExitCode.usage.rawValue
        }
        exit(code)
    }

    static func dispatch(_ command: DaemonCommand) async -> Int32 {
        let paths = DaemonPaths.resolve()
        switch command {
        case .help(let requested):
            if requested {
                Output.line(DaemonCommand.helpText)
                return DaemonExitCode.ok.rawValue
            }
            Output.error(DaemonCommand.helpText)
            return DaemonExitCode.usage.rawValue
        case .run:
            return await RunCommand.run(paths: paths)
        case .login(let email, let noBrowser):
            return await LoginCommand.login(email: email, noBrowser: noBrowser, paths: paths)
        case .loginCallback(let url):
            return await LoginCommand.callback(url, paths: paths)
        case .logout(let email):
            return AccountCommands.logout(email, paths: paths)
        case .status(let json):
            return await LocalCommands.status(json: json, paths: paths)
        case .mode(let feature, let mode):
            return LocalCommands.mode(feature, mode, paths: paths)
        case .initialize:
            return LocalCommands.initialize(paths: paths)
        case .rulesCheck:
            return LocalCommands.rulesCheck(paths: paths)
        case .review(let query):
            return LocalCommands.review(query, paths: paths)
        case .explain(let thread, let account):
            return await AccountCommands.explain(thread, account: account, paths: paths)
        case .backfill(let since, let account, let dryRun):
            return await AccountCommands.backfill(since: since, account: account, dryRun: dryRun, paths: paths)
        case .once(let account, let scope):
            return await OnceCommand.run(account: account, scope: scope, paths: paths)
        case .debugInvalidateToken(let email):
            return AccountCommands.invalidateToken(email, paths: paths)
        case .debugNoteNow(let email):
            return await AccountCommands.noteNow(email, paths: paths)
        }
    }
}

/// stdout for results, stderr for errors. Nothing here goes to the log.
enum Output {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
