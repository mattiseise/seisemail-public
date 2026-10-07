import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import MailCore

@Suite struct InboxPhotosTests {
    // MARK: Fixtures

    static var landscapeFeed: [String: Any] { ["image": [
        "title": "File:Rain Quail in Bhigwan August 2025 by Tisha Mukherjee 13.jpg",
        "thumbnail": ["source": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/64/Rain_Quail.jpg/960px-Rain_Quail.jpg?utm_source=commons.wikimedia.org&utm_content=thumbnail",
                      "width": 640, "height": 427],
        "image": ["source": "https://upload.wikimedia.org/wikipedia/commons/6/64/Rain_Quail.jpg?utm_source=commons.wikimedia.org&utm_content=original",
                  "width": 4399, "height": 2932],
        "artist": ["html": "<a href=\"//commons.wikimedia.org/wiki/User:Tisha_Mukherjee\">Tisha Mukherjee</a>", "text": "Tisha Mukherjee"],
        "license": ["type": "CC BY-SA 4.0", "code": "cc-by-sa-4.0", "url": "https://creativecommons.org/licenses/by-sa/4.0"],
        "file_page": "https://commons.wikimedia.org/wiki/File:Rain_Quail.jpg",
    ]] }

    static func feed(_ edit: (inout [String: Any]) -> Void) -> Data {
        var image = landscapeFeed["image"] as! [String: Any]
        edit(&image)
        return json(["image": image])
    }

    /// A real (tiny) JPEG, so the ImageIO check passes.
    static let jpeg: Data = {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }()

    static let png: Data = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }()

    static let day = 20_733                                     // 7.10.2026

    func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inbox-photos-\(UUID().uuidString)", isDirectory: true)
    }

    /// A bundle directory with `count` photos (a.jpg, b.jpg, …) and their credits.
    func bundle(count: Int, missing: Set<String> = []) throws -> URL {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = (0..<count).map { String(UnicodeScalar(UInt8(97 + $0))) + ".jpg" }
        for name in names where !missing.contains(name) { try Self.jpeg.write(to: dir.appendingPathComponent(name)) }
        let entries = names.map { ["file": $0, "title": "Kuva \($0)", "artist": "Kuvaaja", "license": "CC0",
                                   "licenseURL": "https://creativecommons.org/publicdomain/zero/1.0/",
                                   "sourceURL": "https://commons.wikimedia.org/wiki/File:\($0)"] }
        try json(entries).write(to: dir.appendingPathComponent("credits.json"))
        return dir
    }

    /// Feed → `feed`, image → `image`; counts the requests of each kind.
    func store(bundled: BundledPhotos = BundledPhotos(directory: URL(fileURLWithPath: "/nonexistent")),
               clock: TestClock = TestClock(D(1_791_320_400)), cache: URL? = nil,
               feed: @escaping @Sendable () throws -> (Int, Data) = { (200, json(InboxPhotosTests.landscapeFeed)) },
               image: @escaping @Sendable () throws -> (Int, Data) = { (200, InboxPhotosTests.jpeg) })
        -> (DailyPhotoStore, StubTransport) {
        let transport = StubTransport { request in
            request.url!.host == "api.wikimedia.org" ? try feed() : try image()
        }
        let store = DailyPhotoStore(cacheDirectory: cache ?? tempDirectory(), bundled: bundled, transport: transport,
                                    userAgent: "seisemail-test", now: clock.closure)
        return (store, transport)
    }

    // MARK: Bundled photos

    @Test func bundledPhotosCycleByDayAndSkipMissingFiles() throws {
        let photos = BundledPhotos(directory: try bundle(count: 3, missing: ["b.jpg"]))
        #expect(photos.photos.map(\.fileURL.lastPathComponent) == ["a.jpg", "c.jpg"])
        #expect(photos.photo(day: 10)?.fileURL.lastPathComponent == "a.jpg")
        #expect(photos.photo(day: 11)?.fileURL.lastPathComponent == "c.jpg")
        #expect(photos.photo(day: -1)?.fileURL.lastPathComponent == "c.jpg")
        #expect(photos.photo(day: 10)?.isDaily == false)
        #expect(photos.photo(day: 10)?.credit.line == "Kuva: Kuvaaja · CC0")
    }

    @Test func noCreditsMeansNoPhotos() {
        let photos = BundledPhotos(directory: tempDirectory())
        #expect(photos.photos.isEmpty)
        #expect(photos.photo(day: Self.day) == nil)
    }

    /// The shipped Resources/InboxZero: every photo has a credit with an allowed licence and a Commons source,
    /// and every credit has its photo.
    @Test func shippedPhotosAreAllCredited() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/InboxZero")
        let photos = BundledPhotos(directory: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }
        #expect((5...10).contains(photos.photos.count))
        #expect(Set(photos.photos.map(\.fileURL.lastPathComponent)) == Set(files))
        for photo in photos.photos {
            let c = photo.credit
            #expect(["CC0", "CC BY 4.0", "CC BY-SA 3.0", "CC BY-SA 4.0"].contains(c.license), "\(c.license)")
            #expect(c.sourceURL.hasPrefix("https://commons.wikimedia.org/wiki/File:"))
            #expect(c.licenseURL.contains("creativecommons.org"))
            #expect(!c.artist.isEmpty && !c.title.isEmpty)
            #expect(Self.isJPEG(try Data(contentsOf: photo.fileURL)))
        }
    }

    static func isJPEG(_ data: Data) -> Bool { DailyPhotoStore.isJPEG(data) }

    // MARK: Feed parsing (untrusted)

    @Test func landscapeFeedGivesTheResizedThumbnailWithCredit() throws {
        let candidate = try #require(DailyPhotoStore.candidate(fromFeed: json(Self.landscapeFeed)))
        #expect(candidate.url.absoluteString
            == "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/64/Rain_Quail.jpg/1920px-Rain_Quail.jpg")
        #expect(candidate.credit == PhotoCredit(
            title: "Rain Quail in Bhigwan August 2025 by Tisha Mukherjee 13", artist: "Tisha Mukherjee",
            license: "CC BY-SA 4.0", licenseURL: "https://creativecommons.org/licenses/by-sa/4.0",
            sourceURL: "https://commons.wikimedia.org/wiki/File:Rain_Quail.jpg", modified: "pienennetty 1920 px leveäksi"))
    }

    @Test func smallOriginalIsUsedAsIsWithoutTracking() throws {
        let data = Self.feed { $0["image"] = ["source": "https://upload.wikimedia.org/wikipedia/commons/6/64/Small.jpg?utm_source=x",
                                              "width": 1600, "height": 1000] }
        let candidate = try #require(DailyPhotoStore.candidate(fromFeed: data))
        #expect(candidate.url.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/6/64/Small.jpg")
        #expect(candidate.credit.modified == nil)
    }

    @Test func portraitPNGForeignHostOrUnlicensedPicturesAreRejected() {
        let rejected: [Data] = [
            Self.feed { $0["image"] = ["source": "https://upload.wikimedia.org/a.jpg", "width": 4480, "height": 5973] },
            Self.feed { $0["image"] = ["source": "https://upload.wikimedia.org/a.jpg", "width": 1000, "height": 1000] },
            Self.feed { $0["title"] = "File:Map.png" },
            Self.feed { $0["title"] = "File:Diagram.svg" },
            Self.feed { $0["license"] = ["code": "x"] },
            Self.feed { $0["license"] = ["type": "  "] },
            Self.feed { $0["thumbnail"] = nil; $0["image"] = ["source": "https://evil.example/a.jpg", "width": 1600, "height": 1000] },
            Self.feed { $0["thumbnail"] = nil; $0["image"] = ["source": "http://upload.wikimedia.org/a.jpg", "width": 1600, "height": 1000] },
            Self.feed { $0["thumbnail"] = ["source": "https://evil.example/thumb/960px-a.jpg", "width": 960, "height": 640] },
            json(["tfa": ["title": "Artikkeli"]]),
            Data("not json".utf8),
        ]
        for (i, data) in rejected.enumerated() {
            #expect(DailyPhotoStore.candidate(fromFeed: data) == nil, "case \(i)")
        }
    }

    @Test func creditTextIsSanitised() throws {
        let data = Self.feed {
            $0["artist"] = ["text": "Jane\n\u{0007}Doe\t " + String(repeating: "x", count: 200)]
            $0["file_page"] = "javascript:alert(1)"
            $0["license"] = ["type": "CC BY 4.0", "url": "javascript:alert(1)"]
        }
        let credit = try #require(DailyPhotoStore.candidate(fromFeed: data)).credit
        #expect(credit.artist.hasPrefix("Jane Doe xxx"))
        #expect(credit.artist.count == 80 && credit.artist.hasSuffix("…"))
        #expect(credit.sourceURL == "https://commons.wikimedia.org/wiki/Main_Page")
        #expect(credit.licenseURL == "")
    }

    @Test func missingArtistIsCreditedToCommons() throws {
        let credit = try #require(DailyPhotoStore.candidate(fromFeed: Self.feed { $0["artist"] = nil })).credit
        #expect(credit.line == "Kuva: Wikimedia Commons · CC BY-SA 4.0")
    }

    @Test func thumbnailWidthChangesOnlyTheLastPathComponent() {
        #expect(DailyPhotoStore.thumbnail("https://thumb.wikimedia.org/c/thumb/a/ab/300px-x.jpg/960px-300px-x.jpg", width: 1920)
            == "https://thumb.wikimedia.org/c/thumb/a/ab/300px-x.jpg/1920px-300px-x.jpg")
        #expect(DailyPhotoStore.thumbnail("https://upload.wikimedia.org/c/a/ab/x.jpg", width: 1920) == nil)
    }

    // MARK: Store

    @Test func helsinkiDayRollsOverAtLocalMidnight() {
        #expect(DailyPhotoStore.day(of: D(1_791_061_140)) == 20_729)   // 3.10.2026 23.59 Helsinki
        #expect(DailyPhotoStore.day(of: D(1_791_061_260)) == 20_730)   // 4.10.2026 00.01 Helsinki
    }

    @Test func refreshCachesThePictureOnceAndPrefersItOverTheBundle() async throws {
        let bundled = BundledPhotos(directory: try bundle(count: 2))
        let (store, transport) = store(bundled: bundled)
        #expect(store.photo(day: Self.day)?.isDaily == false)

        #expect(await store.refresh(day: Self.day))
        let photo = try #require(store.photo(day: Self.day))
        #expect(photo.isDaily)
        #expect(photo.credit.artist == "Tisha Mukherjee")
        #expect(try Data(contentsOf: photo.fileURL) == Self.jpeg)
        #expect(transport.requests.first?.url?.absoluteString
            == "https://api.wikimedia.org/feed/v1/wikipedia/fi/featured/2026/10/07")
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "seisemail-test" })

        #expect(await store.refresh(day: Self.day) == false)
        #expect(transport.requests.count == 2)                         // feed + image, once
        #expect(store.photo(day: Self.day, daily: false)?.isDaily == false)   // turned off: the bundle
        #expect(store.photo(day: Self.day + 1)?.isDaily == false)
    }

    @Test func concurrentRefreshesShareOneDownload() async {
        let (store, transport) = store()
        async let a = store.refresh(day: Self.day)
        async let b = store.refresh(day: Self.day)
        _ = await (a, b)
        #expect(transport.requests.count == 2)
    }

    @Test func unusablePictureIsNotAskedForAgainThatDay() async throws {
        let cases: [(feed: Data, image: (Int, Data))] = [
            (Self.feed { $0["title"] = "File:Map.png" }, (200, Self.jpeg)),
            (json(Self.landscapeFeed), (200, Self.png)),                                 // says .jpg, is not
            (json(Self.landscapeFeed), (404, Data())),
            (json(Self.landscapeFeed), (200, Data(count: DailyPhotoStore.maxBytes + 1))),
        ]
        for (i, c) in cases.enumerated() {
            let (store, transport) = store(feed: { (200, c.feed) }, image: { c.image })
            #expect(await store.refresh(day: Self.day) == false, "case \(i)")
            let requests = transport.requests.count
            #expect(await store.refresh(day: Self.day) == false, "case \(i)")
            #expect(transport.requests.count == requests, "case \(i)")
            #expect(store.photo(day: Self.day)?.isDaily != true, "case \(i)")
        }
    }

    @Test func failedFetchIsRetriedAfterHalfAnHour() async {
        let clock = TestClock(D(1_791_320_400))
        let offline = Mutex(true)
        let (store, transport) = store(clock: clock, feed: {
            if offline.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return (200, json(InboxPhotosTests.landscapeFeed))
        })
        #expect(await store.refresh(day: Self.day) == false)
        offline.withLock { $0 = false }
        clock.advance(by: 29 * 60)
        #expect(await store.refresh(day: Self.day) == false)
        #expect(transport.requests.count == 1)
        clock.advance(by: 60)
        #expect(await store.refresh(day: Self.day))
        #expect(transport.requests.count == 3)
    }

    @Test func serverErrorIsRetriedNotMarkedUnusable() async {
        let clock = TestClock(D(1_791_320_400))
        let (store, transport) = store(clock: clock, feed: { (503, Data()) })
        #expect(await store.refresh(day: Self.day) == false)
        #expect(FileManager.default.fileExists(atPath: store.cacheDirectory.appendingPathComponent("daily-\(Self.day).none").path) == false)
        clock.advance(by: 31 * 60)
        #expect(await store.refresh(day: Self.day) == false)
        #expect(transport.requests.count == 2)
    }

    @Test func daysOlderThanAWeekArePruned() async throws {
        let cache = tempDirectory()
        let (store, _) = store(cache: cache)
        #expect(await store.refresh(day: Self.day - 8))
        #expect(await store.refresh(day: Self.day - 7))
        #expect(await store.refresh(day: Self.day))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        #expect(names == ["daily-\(Self.day - 7).jpg", "daily-\(Self.day - 7).json",
                          "daily-\(Self.day).jpg", "daily-\(Self.day).json"])
    }
}
