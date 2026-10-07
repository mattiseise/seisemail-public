import Darwin
import Foundation
import Synchronization

public enum InstanceLockError: Error, Equatable, Sendable {
    /// Another process (or another open of the file) holds the lock.
    case busy
    case io(Int32)
}

/// Single instance (D14): `flock(LOCK_EX|LOCK_NB)` on `daemon/daemon.lock`. The kernel drops the lock when
/// the process dies, so a crash never leaves it stale. `run` exits 75 when busy; `once` refuses.
public final class InstanceLock: Sendable {
    /// `EX_TEMPFAIL`: launchd's `KeepAlive {SuccessfulExit=false}` restarts the job after `ThrottleInterval`.
    public static let busyExitCode: Int32 = DaemonExitCode.lockHeld.rawValue

    private let fd: Mutex<Int32>
    public let url: URL

    /// Takes the lock or throws `.busy`. Writes this process's pid into the file (for humans; not trusted).
    public init(_ url: URL) throws(InstanceLockError) {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .io(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? .busy : .io(code)
        }
        fchmod(fd, 0o600)
        let pid = Array("\(getpid())\n".utf8)
        if ftruncate(fd, 0) == 0 {
            _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        self.fd = Mutex(fd)
        self.url = url
    }

    /// Releases the lock (also on deinit). The file stays.
    public func release() {
        fd.withLock { fd in
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}
