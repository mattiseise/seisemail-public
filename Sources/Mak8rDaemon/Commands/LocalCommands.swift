import DaemonCore
import Foundation

/// Commands that read or write only local files: `status`, `mode`, `init`, `rules check`, `review`.
enum LocalCommands {
    /// `status [--json]`. In text mode a missing or stopped status gets a 3 s grace, so `make daemon-install`
    /// sees the freshly bootstrapped daemon's first write.
    static func status(json: Bool, paths: DaemonPaths) async -> Int32 {
        var status = StatusFile.read(paths.status)
        if !json, status == nil || status?.state != "running" {
            let first = status?.writtenAt
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(250))
                status = StatusFile.read(paths.status)
                if let status, status.state == "running", status.writtenAt != first { break }
            }
        }
        let (text, code) = json ? StatusReport.json(status, now: Date()) : StatusReport.render(status, now: Date())
        Output.line(text)
        return code.rawValue
    }

    static func mode(_ feature: DaemonCommand.Feature, _ mode: FeatureMode, paths: DaemonPaths) -> Int32 {
        do {
            let config = try DaemonSetup.setMode(feature, mode, paths: paths)
            let name = feature == .wake ? "herätys" : "lajittelu"
            Output.line("Tila vaihdettu: \(name) \(mode.rawValue) (herätys \(config.wake.rawValue), lajittelu \(config.sorting.rawValue)).")
            Output.line("Daemon ottaa muutoksen käyttöön minuutin kuluessa.")
            if feature == .sorting, mode == .live {
                Output.line("Lajittelu kirjoittaa nyt tunnisteita Gmailiin.")
                // §16 stage 4: the shadow start's day from status.json; a placeholder before the daemon knows it.
                let commands = StatusReport.backfillCommands(StatusFile.read(paths.status))
                for command in commands.isEmpty ? ["mak8r-daemon backfill --since <päivä> --dry-run"] : commands {
                    Output.line("Varjojakson ketjut: \(command)")
                }
            }
            return DaemonExitCode.ok.rawValue
        } catch {
            for problem in error.problems { Output.error(problem) }
            Output.error("daemon.json jätettiin ennalleen.")
            return DaemonExitCode.invalidData.rawValue
        }
    }

    static func initialize(paths: DaemonPaths) -> Int32 {
        do {
            let created = try DaemonSetup.initialize(paths: paths)
            if created.isEmpty {
                Output.line("Asetustiedostot ovat jo olemassa: \(paths.config.path), \(paths.rules.path)")
            } else {
                for url in created { Output.line("Luotu: \(url.path)") }
            }
            return DaemonExitCode.ok.rawValue
        } catch {
            Output.error("init epäonnistui: \(error)")
            return DaemonExitCode.unavailable.rawValue
        }
    }

    static func rulesCheck(paths: DaemonPaths) -> Int32 {
        let (text, code) = RulesReport.check(paths: paths)
        if code == .ok { Output.line(text) } else { Output.error(text) }
        return code.rawValue
    }

    static func review(_ query: ReviewQuery, paths: DaemonPaths) -> Int32 {
        let now = Date()
        do {
            let entries = try ReviewReport.filter(ReviewReport.load(paths: paths), query, now: now)
            Output.line(ReviewReport.render(entries, summary: query.summary, now: now))
            return DaemonExitCode.ok.rawValue
        } catch {
            Output.error("mak8r-daemon: \(error.message)")
            return DaemonExitCode.usage.rawValue
        }
    }
}
