import Foundation

/// `login` without `--no-browser`: `/usr/bin/open <url>`. A failure (sandbox, no GUI session) is ignored;
/// the URL is printed anyway.
enum BrowserOpener {
    static func open(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
