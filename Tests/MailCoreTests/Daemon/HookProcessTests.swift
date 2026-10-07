import Foundation
import Testing
@testable import DaemonCore

/// §11.3 `notify.command`: the hook is waited for at most `timeout`, stopped for good (TERM, then KILL), and a
/// cancelled wait (shutdown) ends at once without spinning.
@Suite struct HookProcessTests {
    func hook(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @Test func aQuickHookReportsItsExitStatus() async throws {
        let process = try hook("exit 3")
        #expect(await HookProcess.wait(for: process, timeout: 5) == .exited(3))
    }

    @Test func aHookIgnoringTermIsKilledAfterTheTimeout() async throws {
        let process = try hook("trap '' TERM; exec /bin/sleep 30")
        #expect(await HookProcess.wait(for: process, timeout: 0.3, grace: 0.2) == .timedOut)
        #expect(await eventually { !process.isRunning })
    }

    @Test func cancellationEndsTheWaitAtOnceAndStopsTheHook() async throws {
        let process = try hook("trap '' TERM; exec /bin/sleep 30")
        let start = Date()
        let task = Task { await HookProcess.wait(for: process, timeout: 5, grace: 0.2) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(await eventually { !process.isRunning })
    }
}
