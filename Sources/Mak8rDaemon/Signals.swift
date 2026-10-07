import Darwin
import Dispatch

/// §6.1 step 1 and §6.8: TERM and INT are ignored at the C level and delivered through dispatch sources,
/// which cancel the root task (state saved, status `stopped`, exit 0 within `ExitTimeOut`). HUP stays ignored.
enum Signals {
    static func ignoreAll() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
    }

    /// Keep the returned sources alive for as long as the handler should run.
    static func onTermination(_ handler: @escaping @Sendable () -> Void) -> [any DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}
