import Darwin
import Foundation

/// Waiting for the `notify.command` hook (design §11.3): the executable's `CommandNotifier` starts the
/// `Process`, this waits for it.
public enum HookProcess {
    public enum Outcome: Sendable, Equatable {
        case exited(Int32)
        /// Still running at the timeout: stopped.
        case timedOut
        /// The waiting task was cancelled (shutdown): the hook was stopped and the wait ended at once.
        case cancelled
    }

    /// Polls every 100 ms until the hook exits or `timeout` passes. A hook still running then (or when the
    /// task is cancelled) gets SIGTERM, `grace` seconds, then SIGKILL, so no stuck copy is left behind.
    public static func wait(for process: Process, timeout: TimeInterval, grace: TimeInterval = 1) async -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        var cancelled = false
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                cancelled = true                               // shutdown: stop the hook, never spin
                break
            }
        }
        guard process.isRunning else {
            return cancelled ? .cancelled : .exited(process.terminationStatus)
        }
        process.terminate()
        let killAt = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < killAt {
            await pause(0.05)                                  // not cancellable: the hook must be stopped
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return cancelled ? .cancelled : .timedOut
    }

    /// A short sleep that ignores cancellation.
    private static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}
