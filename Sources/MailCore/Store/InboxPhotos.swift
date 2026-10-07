import Foundation
import ImageIO

/// Who made an Inbox 0 photo and under which licence. CC BY and CC BY-SA require the author, the licence and a
/// note of changes; the Mac app shows `line` on the photo and links to `sourceURL`.
public struct PhotoCredit: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String
    public var license: String
    public var licenseURL: String
    public var sourceURL: String
    public var modified: String?

    public init(title: String, artist: String, license: String, licenseURL: String, sourceURL: String, modified: String? = nil) {
        self.title = title
        self.artist = artist
        self.license = license
        self.licenseURL = licenseURL
        self.sourceURL = sourceURL
        self.modified = modified
    }

    /// "Kuva: Giles Laurent · CC BY-SA 4.0"
    public var line: String { "Kuva: \(artist) · \(license)" }
}

public struct InboxPhoto: Sendable, Equatable {
    public var fileURL: URL
    public var credit: PhotoCredit
    /// From Wikimedia's picture of the day rather than the bundle.
    public var isDaily: Bool
}

/// The photos shipped in the app (Resources/InboxZero: JPEGs + credits.json), one per day in turn, for days
/// without a usable picture of the day (offline, turned off, or not a landscape photo).
public struct BundledPhotos: Sendable {
    private struct Entry: Codable {
        var file: String
        var title: String
        var artist: String
        var license: String
        var licenseURL: String
        var sourceURL: String
        var modified: String?
    }

    public let photos: [InboxPhoto]

    /// Entries whose file is missing are skipped; a missing or broken credits.json gives no photos.
    public init(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("credits.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            photos = []
            return
        }
        photos = entries.compactMap { e in
            let url = directory.appendingPathComponent(e.file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return InboxPhoto(fileURL: url, credit: PhotoCredit(title: e.title, artist: e.artist, license: e.license,
                                                                  licenseURL: e.licenseURL, sourceURL: e.sourceURL,
                                                                  modified: e.modified), isDaily: false)
        }
    }

    /// In turn by day, so two days in a row never show the same photo (with two or more).
    public func photo(day: Int) -> InboxPhoto? {
        photos.isEmpty ? nil : photos[((day % photos.count) + photos.count) % photos.count]
    }
}

/// Wikimedia Commons' picture of the day (api.wikimedia.org featured feed), downloaded once per Helsinki day and
/// cached for a week. Feed content is untrusted: only https JPEG landscape photos from Wikimedia's own hosts, at
/// most `maxBytes`, with a licence; anything else falls back to the bundled photos.
public actor DailyPhotoStore {
    public static let maxBytes = 8 * 1024 * 1024
    /// After a failed fetch (offline, server error) the day is tried again after this long.
    static let retryAfter: TimeInterval = 30 * 60
    static let keepDays = 7

    public nonisolated let cacheDirectory: URL
    public nonisolated let bundled: BundledPhotos
    private let transport: any HTTPTransport
    private let userAgent: String
    private let now: @Sendable () -> Date
    private var failedAt: [Int: Date] = [:]
    private var inFlight: [Int: Task<Bool, Never>] = [:]

    public init(cacheDirectory: URL, bundled: BundledPhotos, transport: any HTTPTransport = URLSessionTransport(),
                userAgent: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cacheDirectory = cacheDirectory
        self.bundled = bundled
        self.transport = transport
        self.userAgent = userAgent
        self.now = now
    }

    /// The Helsinki civil day the picture belongs to.
    public static func day(of date: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> Int {
        CivilTime.localDay(of: date, in: timeZone)
    }

    /// The cached picture of the day (when `daily`), else the bundled photo for the day. No network.
    public nonisolated func photo(day: Int, daily: Bool = true) -> InboxPhoto? {
        let image = imageURL(day), credit = creditURL(day)
        if daily, FileManager.default.fileExists(atPath: image.path),
           let data = try? Data(contentsOf: credit), let decoded = try? JSONDecoder().decode(PhotoCredit.self, from: data) {
            return InboxPhoto(fileURL: image, credit: decoded, isDaily: true)
        }
        return bundled.photo(day: day)
    }

    /// Downloads the day's picture once: no-op when it is cached, the day's feed had no usable photo, or a fetch
    /// failed less than `retryAfter` ago. Returns true when a new photo was cached. Prunes days older than a week.
    /// Concurrent calls for the same day (two windows) share one download.
    @discardableResult
    public func refresh(day: Int) async -> Bool {
        if let running = inFlight[day] { return await running.value }
        prune(before: day - Self.keepDays)
        let fm = FileManager.default
        if fm.fileExists(atPath: imageURL(day).path) || fm.fileExists(atPath: noneURL(day).path) { return false }
        if let failed = failedAt[day], now().timeIntervalSince(failed) < Self.retryAfter { return false }
        let task = Task { await fetch(day: day) }
        inFlight[day] = task
        let cached = await task.value
        inFlight[day] = nil
        return cached
    }

    /// Thrown for a picture that will not become usable on a retry (wrong kind, too big, gone).
    private struct Unusable: Error {}

    private func fetch(day: Int) async -> Bool {
        let fm = FileManager.default
        do {
            guard let candidate = try await feedPicture(day: day) else { throw Unusable() }
            let data = try await download(candidate.url)
            guard Self.isJPEG(data) else { throw Unusable() }
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: imageURL(day), options: .atomic)
            try JSONEncoder().encode(candidate.credit).write(to: creditURL(day), options: .atomic)
            failedAt[day] = nil
            return true
        } catch is Unusable {
            try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? Data().write(to: noneURL(day), options: .atomic)               // the bundled photo today: don't ask again
            return false
        } catch {
            failedAt[day] = now()                                               // offline or server error: retry later
            return false
        }
    }

    // MARK: Feed

    struct Candidate: Equatable {
        var url: URL
        var credit: PhotoCredit
    }

    private func feedPicture(day: Int) async throws -> Candidate? {
        let (y, m, d) = CivilTime.civil(days: day)
        let feed = URL(string: String(format: "https://api.wikimedia.org/feed/v1/wikipedia/fi/featured/%04d/%02d/%02d", y, m, d))!
        var request = URLRequest(url: feed)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return Self.candidate(fromFeed: data)
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (data, response) = try await transport.send(request)
        if (400..<500).contains(response.statusCode) { throw Unusable() }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard data.count <= Self.maxBytes else { throw Unusable() }
        return data
    }

    private struct FeedDTO: Decodable {
        struct Source: Decodable { var source: String; var width: Int; var height: Int }
        struct Text: Decodable { var text: String? }
        struct License: Decodable { var type: String?; var url: String? }
        struct Picture: Decodable {
            var title: String
            var thumbnail: Source?
            var image: Source
            var artist: Text?
            var license: License?
            var file_page: String?
        }
        var image: Picture?
    }

    /// The feed's picture when it is a usable landscape JPEG with a licence, else nil.
    static func candidate(fromFeed data: Data) -> Candidate? {
        guard let picture = (try? JSONDecoder().decode(FeedDTO.self, from: data))?.image else { return nil }
        let lower = picture.title.lowercased()
        guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else { return nil }
        guard picture.image.height > 0, Double(picture.image.width) / Double(picture.image.height) >= 1.2 else { return nil }
        guard let license = clean(picture.license?.type, max: 40), !license.isEmpty else { return nil }
        let resized = picture.image.width > 1920 ? picture.thumbnail.flatMap { thumbnail($0.source, width: 1920) } : nil
        guard let url = wikimediaURL(resized ?? picture.image.source) else { return nil }
        var title = String(picture.title.dropFirst(picture.title.hasPrefix("File:") ? 5 : 0))
        if let dot = title.lastIndex(of: ".") { title = String(title[..<dot]) }
        let artist = clean(picture.artist?.text, max: 80).flatMap { $0.isEmpty ? nil : $0 } ?? "Wikimedia Commons"
        let licenseURL = picture.license?.url.flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? $0 : nil } ?? ""
        let page = picture.file_page.flatMap { $0.hasPrefix("https://commons.wikimedia.org/") ? $0 : nil }
            ?? "https://commons.wikimedia.org/wiki/Main_Page"
        let credit = PhotoCredit(title: clean(title, max: 120) ?? "", artist: artist, license: license,
                                 licenseURL: licenseURL, sourceURL: page,
                                 modified: resized == nil ? nil : "pienennetty 1920 px leveäksi")
        return Candidate(url: url, credit: credit)
    }

    /// The thumbnail URL at another width: ".../960px-Name.jpg" → ".../1920px-Name.jpg" (1920 is one of Wikimedia's
    /// standard thumbnail steps). Only the last path component is touched; nil when it is not "<digits>px-…".
    static func thumbnail(_ string: String, width: Int) -> String? {
        guard var parts = URLComponents(string: string) else { return nil }
        let path = parts.percentEncodedPath
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let name = path[path.index(after: slash)...]
        let digits = name.prefix(while: \.isASCII).prefix(while: \.isNumber)
        guard !digits.isEmpty, name.dropFirst(digits.count).hasPrefix("px-") else { return nil }
        parts.percentEncodedPath = path[...slash] + "\(width)px-" + name.dropFirst(digits.count + 3)
        return parts.string
    }

    /// https on Wikimedia's image hosts only, without tracking parameters.
    static func wikimediaURL(_ string: String) -> URL? {
        guard var parts = URLComponents(string: string), parts.scheme == "https",
              let host = parts.host, ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(host) else { return nil }
        parts.query = nil
        return parts.url
    }

    /// Plain single-line text: control characters removed, whitespace collapsed, at most `max` characters.
    static func clean(_ text: String?, max: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > max ? String(collapsed.prefix(max - 1)) + "…" : collapsed
    }

    static func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) else { return false }
        return (type as String) == "public.jpeg"
    }

    // MARK: Files

    private nonisolated func imageURL(_ day: Int) -> URL { cacheDirectory.appendingPathComponent("daily-\(day).jpg") }
    private nonisolated func creditURL(_ day: Int) -> URL { cacheDirectory.appendingPathComponent("daily-\(day).json") }
    private nonisolated func noneURL(_ day: Int) -> URL { cacheDirectory.appendingPathComponent("daily-\(day).none") }

    private func prune(before day: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) else { return }
        for name in names where name.hasPrefix("daily-") {
            let number = name.dropFirst("daily-".count).prefix { $0.isNumber || $0 == "-" }
            if let d = Int(number), d < day {
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(name))
            }
        }
    }
}
