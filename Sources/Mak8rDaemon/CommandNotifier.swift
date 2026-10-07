import DaemonCore
import Foundation

/// The opt-in `notify.command` hook (design §11.3, Q12): argv run with `Process` (no shell), environment
/// `MAK8R_EVENT`, `MAK8R_ACCOUNT`, `MAK8R_TEXT` (Finnish, no secrets), 10 s timeout, failures logged.
/// The command is read from `daemon.json` at each event, so editing it needs no restart.
struct CommandNotifier: DaemonNotifier {
    let configStore: ConfigStore
    let log: DaemonLog
    var timeout: TimeInterval = 10

    func post(_ e: DaemonEvent) async {
        guard let command = await configStore.current().config.notify.command, let executable = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "HOME": NSHomeDirectory(),
            "MAK8R_EVENT": e.name,
            "MAK8R_ACCOUNT": e.account ?? "",
            "MAK8R_TEXT": e.text(),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error(e.account, "ilmoituskomento ei käynnistynyt (\(e.name)): \(error.localizedDescription)")
            return
        }
        switch await HookProcess.wait(for: process, timeout: timeout) {
        case .timedOut:
            log.error(e.account, "ilmoituskomento ei päättynyt \(Int(timeout)) s:ssa (\(e.name)): lopetettiin")
        case .cancelled:
            log.notice(e.account, "ilmoituskomento lopetettiin sammutuksen vuoksi (\(e.name))")
        case .exited(let status) where status != 0:
            log.error(e.account, "ilmoituskomento päättyi koodilla \(status) (\(e.name))")
        case .exited:
            log.info(e.account, "ilmoituskomento ajettu (\(e.name))")
        }
    }
}
