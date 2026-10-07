import Foundation
import Testing
@testable import DaemonCore

/// §6.1 step 1: TERM/INT handlers exist from the first moment; a signal before the root task exists is kept
/// and cancels it as soon as it is attached (clean exit 0 instead of launchd's SIGKILL after ExitTimeOut).
@Suite struct TerminationLatchTests {
    @Test func aSignalBeforeTheTaskExistsCancelsItWhenAttached() async {
        let latch = TerminationLatch()
        latch.request()
        #expect(latch.isRequested)
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return true
        }
        latch.attach(task)
        #expect(await task.value)
    }

    @Test func aSignalAfterAttachCancelsTheTask() async {
        let latch = TerminationLatch()
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return true
        }
        latch.attach(task)
        #expect(!latch.isRequested)
        latch.request()
        #expect(await task.value)
    }
}
