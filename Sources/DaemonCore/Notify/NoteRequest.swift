import Foundation

/// `debug note-now` while the daemon runs: `requests/note-<key>-<stamp>.json` with `{requestedAt}`. The
/// running account inserts the expiry note on its next sync tick and deletes the file, so the note's ID
/// lands in the daemon's own state and the note is archived after the next login. (Writing the state
/// from the CLI would race the daemon, which owns it.)
public struct NoteRequest: Sendable, Equatable {
    public var account: String
    public var requestedAt: Date

    public init(account: String, requestedAt: Date) {
        self.account = account.lowercased()
        self.requestedAt = requestedAt
    }

    private struct Body: Codable {
        var requestedAt: Date
    }

    @discardableResult
    public func write(paths: DaemonPaths) throws -> URL {
        let url = paths.noteRequest(account, at: requestedAt)
        try AtomicFile.ensureDirectory(paths.requests, mode: 0o700)
        try AtomicFile.write(try DaemonJSON.encoder().encode(Body(requestedAt: requestedAt)), to: url, mode: 0o600)
        return url
    }

    /// Request files of `account`, oldest first.
    public static func pending(account: String, in directory: URL) -> [URL] {
        let prefix = "note-\(DaemonPaths.key(account))-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { DaemonPaths.isRequest($0, prefix: prefix) }.sorted()
            .map { directory.appendingPathComponent($0) }
    }
}
