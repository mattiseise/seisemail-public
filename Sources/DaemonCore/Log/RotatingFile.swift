import Darwin
import Foundation
import Synchronization

/// Where log lines go. `RotatingFile` in the daemon; tests use an in-memory sink.
public protocol LogSink: Sendable {
    /// One line without its newline.
    func write(_ line: String)
}

/// An append-only file with its own `O_APPEND` handle (mode 0600), rotated after a write that takes it past
/// `maxBytes`: `name` → `name.1` → … → `name.<keep>` (the oldest is dropped).
public final class RotatingFile: LogSink {
    private struct State {
        var fd: Int32 = -1
        var size: Int64 = 0
        /// The last write stopped mid-line (disk full): the next one starts with a newline.
        var lineOpen = false
    }

    public let url: URL
    public let maxBytes: Int64
    public let keep: Int
    private let state = Mutex(State())

    public init(url: URL, maxBytes: Int64, keep: Int = 3) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
    }

    deinit {
        state.withLock { s in
            if s.fd >= 0 { close(s.fd) }
        }
    }

    public func write(_ line: String) {
        state.withLock { s in
            if s.fd < 0 { open(&s) }
            guard s.fd >= 0 else { return }
            let bytes = Array(((s.lineOpen ? "\n" : "") + line + "\n").utf8)
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(s.fd, $0.baseAddress! + offset, $0.count - offset) }
                if n > 0 {
                    offset += n
                    s.size += Int64(n)
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    break                                      // ENOSPC and the like: drop the rest
                }
            }
            if offset == bytes.count { s.lineOpen = false } else if offset > 0 { s.lineOpen = true }
            if s.size >= maxBytes { rotate(&s) }
        }
    }

    /// The rotated file names, newest first: `name.1` … `name.<keep>`.
    public var rotatedURLs: [URL] {
        (1...max(keep, 1)).map { URL(fileURLWithPath: url.path + ".\($0)") }
    }

    private func open(_ s: inout State) {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        fchmod(fd, 0o600)
        var info = stat()
        s.size = fstat(fd, &info) == 0 ? Int64(info.st_size) : 0
        s.fd = fd
    }

    private func rotate(_ s: inout State) {
        close(s.fd)
        s.fd = -1
        s.lineOpen = false
        let base = url.path
        if keep > 0 {
            unlink("\(base).\(keep)")
            if keep > 1 {
                for i in stride(from: keep - 1, through: 1, by: -1) {
                    Darwin.rename("\(base).\(i)", "\(base).\(i + 1)")
                }
            }
            Darwin.rename(base, "\(base).1")
        } else {
            unlink(base)
        }
        open(&s)
    }

    /// Truncates `url` to zero when it is larger than `limit` (launchd's stdout/stderr files at start).
    public static func truncate(_ url: URL, ifLargerThan limit: Int64) {
        var info = stat()
        guard stat(url.path, &info) == 0, Int64(info.st_size) > limit else { return }
        Darwin.truncate(url.path, 0)
    }
}
