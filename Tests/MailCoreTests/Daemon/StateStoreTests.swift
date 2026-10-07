import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §9.2–§9.3 through the runner and the files themselves: 0600 files, atomic write with `.bak`, the load order
/// current → `.bak` → bootstrap, quarantine of undecodable files, future schema untouched, and the 10-minute
/// watermark-only debounce.
@Suite struct StateStoreTests {
    let env: DaemonEnv

    init() throws {
        env = try DaemonEnv()
        try env.writeToken()
        try env.setConfig(sorting: .shadow)
    }

    var fake: SyncFakeGmail { env.fake }
    var stateURL: URL { env.paths.state(env.email) }
    var bakURL: URL { URL(fileURLWithPath: stateURL.path + ".bak") }

    func daemonFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: env.paths.daemon.path)) ?? []
    }

    @Test func pathsUseTheAccountKey() {
        #expect(stateURL.lastPathComponent == "state-matti@example.fi.json")
        #expect(stateURL.deletingLastPathComponent().standardizedFileURL == env.paths.daemon.standardizedFileURL)
    }

    @Test func bootstrapWritesA0600FileAndKeepsTheOldOneAsBak() async throws {
        await tick(env.runner(), limit: 6) { (env.storedBackfill?["phase"] as? String) == "done" }
        #expect(posixMode(stateURL) == 0o600)
        #expect(posixMode(env.paths.daemon) == 0o700)
        #expect(FileManager.default.fileExists(atPath: bakURL.path))      // more than one write so far
        #expect(posixMode(bakURL) == 0o600)
        #expect((jsonObject(bakURL)?["schema"] as? Int) == 1)
        #expect(!daemonFiles().contains { $0.hasPrefix("state-") && !$0.hasSuffix(".json") && !$0.hasSuffix(".bak") })   // no temp files left
    }

    @Test func truncatedCurrentFileFallsBackToBak() async throws {
        try env.seedState(watermark: "1500")
        try FileManager.default.moveItem(at: stateURL, to: bakURL)
        try env.writeFile(Data(#"{"schema": 1, "account": "matti@exa"#.utf8), to: stateURL, mode: 0o600)
        fake.bumpHistory(by: 600)
        _ = await env.runner().syncTick()
        #expect(fake.historyStarts.first == "1500")
        #expect(!fake.calls.contains("profile"))                          // no bootstrap
    }

    @Test func bothFilesUndecodableAreQuarantinedAndTheAccountBootstraps() async throws {
        try env.writeFile(Data("not json".utf8), to: stateURL, mode: 0o600)
        try env.writeFile(Data("{\"schema\": 1".utf8), to: bakURL, mode: 0o600)
        _ = await env.runner().syncTick()
        #expect(daemonFiles().contains { $0.hasPrefix("state-matti@example.fi.json") && $0.contains(".corrupt-") })
        #expect(fake.calls.contains("profile"))
        #expect((env.state()?["schema"] as? Int) == 1)
    }

    @Test func quarantineNameCarriesATimestamp() async throws {
        try env.writeFile(Data("not json".utf8), to: stateURL, mode: 0o600)
        _ = await env.runner().syncTick()
        let name = try #require(daemonFiles().first { $0.contains(".corrupt-") })
        let stamp = String(name.split(separator: "-").last ?? "")
        #expect(stamp.count == 14 && stamp.allSatisfy(\.isNumber))       // yyyyMMddHHmmss
    }

    @Test func futureSchemaLeavesTheAccountUntouched() async throws {
        try env.seedState(watermark: "1000", schema: 2)
        let before = try Data(contentsOf: stateURL)
        let runner = env.runner()
        _ = await runner.syncTick()
        _ = await runner.wakeTick()
        let phase = await runner.phase
        guard case .stateError = phase else {
            Issue.record("expected .stateError, got \(phase)")
            return
        }
        #expect(try Data(contentsOf: stateURL) == before)
        #expect(!FileManager.default.fileExists(atPath: bakURL.path))
        #expect(fake.calls.isEmpty)
    }

    @Test func missingStateBootstraps() async throws {
        _ = await env.runner().syncTick()
        #expect(fake.calls.contains("profile"))
        #expect(FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test func watermarkOnlyChangesAreSavedAtMostEvery10Minutes() async throws {
        try env.seedState(watermark: "1000")
        let runner = env.runner()
        fake.sendMail("s1", to: ["uusi@example.fi"])
        _ = await runner.syncTick()                                       // a sent change: saved at once, with W
        let saved = try #require(env.storedWatermark)
        #expect(saved != "1000")
        env.clock.advance(by: 60)
        fake.bumpHistory(by: 5)                                            // historyId moves on every read toggle
        _ = await runner.syncTick()
        #expect(env.storedWatermark == saved)
        env.clock.advance(by: 4 * 60)
        fake.bumpHistory(by: 5)
        _ = await runner.syncTick()
        #expect(env.storedWatermark == saved)
        env.clock.advance(by: 6 * 60)                                      // 11 min after the last write
        fake.bumpHistory(by: 5)
        let mailbox = fake.historyID
        _ = await runner.syncTick()
        #expect(env.storedWatermark == String(mailbox))
    }

    @Test func sentChangesAreSavedAtOnce() async throws {
        try env.seedState(watermark: "1000")
        fake.sendMail("s1", to: ["uusi@example.fi"])
        _ = await env.runner().syncTick()
        #expect(env.storedSent?["uusi@example.fi"] != nil)
        #expect(env.storedWatermark != "1000")                            // written together with the cache
    }

    @Test func shutdownSavesTheWatermark() async throws {
        try env.seedState(watermark: "1000")
        fake.sendMail("s1", to: ["uusi@example.fi"])
        let runner = env.runner()
        let task = Task { await runner.run() }
        #expect(await drive(env.clock) { fake.historyStarts.count >= 1 })
        #expect(await eventually { env.storedSent?["uusi@example.fi"] != nil })   // saved at once
        let saved = env.storedWatermark
        fake.bumpHistory(by: 3)
        let mailbox = fake.historyID
        #expect(await drive(env.clock) { fake.historyStarts.count >= 2 })
        #expect(await eventually { env.clock.sleeperCount >= 2 })        // that tick has finished
        #expect(env.storedWatermark == saved)                              // debounced while running
        task.cancel()
        await task.value                                                   // run() returns; it never throws
        #expect(env.storedWatermark == String(mailbox))
    }
}
