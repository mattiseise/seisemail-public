import Darwin
import Foundation

public struct FileError: Error, Equatable, Sendable, CustomStringConvertible {
    public var operation: String
    public var path: String
    public var code: Int32

    public init(_ operation: String, _ path: String, _ code: Int32 = errno) {
        self.operation = operation
        self.path = path
        self.code = code
    }

    public var description: String { "\(operation) \(path): \(String(cString: strerror(code))) (\(code))" }
}

/// Durable whole-file writes (design §8.1, §9.3): a fresh temp file (`O_CREAT|O_EXCL`, the final mode)
/// → `F_FULLFSYNC` → [current → `.bak`] → `rename` → fsync of the directory.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o600, keepBackup: Bool = false) throws {
        let path = url.path
        let directory = url.deletingLastPathComponent().path
        let tmp = "\(directory)/.\(url.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode)
        guard fd >= 0 else { throw FileError("open", tmp) }
        var closed = false
        defer {
            if !closed { close(fd) }
        }
        do {
            // The umask may have narrowed the mode; never widen it beyond what was asked.
            guard fchmod(fd, mode) == 0 else { throw FileError("fchmod", tmp) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw FileError("write", tmp)
                    }
                    offset += n
                }
            }
            // F_FULLFSYNC flushes the drive cache too; fall back to fsync where it is unsupported.
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw FileError("fsync", tmp) }
            closed = true
            guard close(fd) == 0 else { throw FileError("close", tmp) }
            if keepBackup, access(path, F_OK) == 0 {
                guard rename(path, path + ".bak") == 0 else { throw FileError("rename", path) }
            }
            guard rename(tmp, path) == 0 else { throw FileError("rename", tmp) }
        } catch {
            unlink(tmp)
            throw error
        }
        syncDirectory(directory)
    }

    /// Creates `url` (and parents) with `mode`. An existing directory with group/other bits beyond `mode`
    /// is tightened when `tighten` (the daemon's own folders).
    public static func ensureDirectory(_ url: URL, mode: mode_t = 0o700, tighten: Bool = true) throws {
        let path = url.path
        var info = stat()
        if stat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw FileError("mkdir", path, ENOTDIR) }
            if tighten, info.st_mode & 0o777 & ~mode != 0 {
                guard chmod(path, mode) == 0 else { throw FileError("chmod", path) }
            }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != path, access(parent.path, F_OK) != 0 {
            try ensureDirectory(parent, mode: 0o755, tighten: false)
        }
        if mkdir(path, mode) != 0, errno != EEXIST { throw FileError("mkdir", path) }
        guard chmod(path, mode) == 0 else { throw FileError("chmod", path) }
    }

    /// Reads a whole file. nil when it does not exist; other failures throw with errno.
    public static func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw FileError("open", url.path)
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw FileError("read", url.path)
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    /// Permission bits of `url`, or nil when it does not exist.
    public static func mode(_ url: URL) -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    /// Identity of the file's current contents: changes on every write, including an atomic replace
    /// within the same clock tick (new inode). nil when it does not exist.
    public static func stamp(_ url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileStamp(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec),
                         size: Int64(info.st_size), inode: UInt64(info.st_ino))
    }

    private static func syncDirectory(_ path: String) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }
}

public struct FileStamp: Equatable, Sendable {
    public var seconds: Int64
    public var nanoseconds: Int64
    public var size: Int64
    public var inode: UInt64
}
