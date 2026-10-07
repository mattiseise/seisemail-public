#if os(macOS)
import AppKit
import MailCore

/// Fork (seisemail): `make screenshots` — the README images, taken from the real app with DemoGmail's made-up
/// mail. Runs only with both `-screenshots <dir>` and MAK8R_DATA_DIR, so it never touches the user's own files.
@MainActor
struct ScreenshotDirector {
    static var outputDirectory: URL? {
        guard AppPaths.overrideRoot != nil, let path = UserDefaults.standard.string(forKey: "screenshots") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    let app: AppModel
    let directory: URL

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let window = await waitForWindow(), let session = app.activeSession else {
            print("screenshots: no window or session")
            exit(1)
        }
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.center()
        seedStreak(email: session.email)
        let store = session.store

        print("screenshots: waiting for the meeting badges (their search starts a minute after launch)…")
        try? await Task.sleep(for: .seconds(66))
        shoot(window, "kasiteltavat")

        await store.select(threadID: "d01")                                  // the Teams invite: join button
        try? await Task.sleep(for: .seconds(2))
        shoot(window, "kokous")
        store.closePeek()
        await settle()

        if store.threads.count > 1 { store.highlight(threadID: store.threads[1].id) }
        app.seise.openMenu(session: session)
        await settle()
        shoot(window, "torkku-valikko")

        for key: SnoozeMenuKey in [.digit(5), .right, .right, .digit(1), .digit(4), .digit(3), .digit(0)] {
            app.seise.handle(key)
        }
        await settle()
        shoot(window, "oma-aika")
        app.seise.closeMenu()

        await store.selectView(SeiseViews.snoozedID)
        await waitUntil { !store.threads.isEmpty }
        await settle()
        shoot(window, "torkku-nakyma")

        await store.selectView(SeiseViews.inboxZeroID)
        await waitUntil { !store.threads.isEmpty }
        TextScale.store.increase()
        TextScale.store.increase()
        await settle()
        shoot(window, "tekstikoko")
        TextScale.store.reset()
        await settle()

        store.checkAll()
        await settle()
        shoot(window, "valinta")
        Task { await store.archive() }
        try? await Task.sleep(for: .seconds(1))
        shoot(window, "arkistointi", jpeg: true)

        await waitUntil(seconds: 20) { if case .inboxZero = store.emptyState { true } else { false } }
        try? await Task.sleep(for: .seconds(4))                              // the archive lands
        await app.refreshNow()                                              // the sidebar counts follow
        try? await Task.sleep(for: .seconds(2))
        shoot(window, "inbox-0", jpeg: true)

        print("screenshots: done → \(directory.path)")
        NSApp.terminate(nil)
    }

    /// Eleven earlier weeks, so the Inbox 0 at the end makes a 12-week streak.
    private func seedStreak(email: String) {
        var weeks = InboxZeroWeeks()
        for back in 1...11 { weeks.record(email: email, now: Date().addingTimeInterval(-Double(back) * 7 * 86_400)) }
        app.seise.streak.replace(with: weeks)
    }

    private func waitForWindow() async -> NSWindow? {
        for _ in 0..<100 {
            if let window = app.mainWindow { return window }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(800)) }

    /// The window as drawn, title-bar area included (the frame view), at 2x. Photo views as JPEG (size).
    private func shoot(_ window: NSWindow, _ name: String, jpeg: Bool = false) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let url = directory.appendingPathComponent(name + (jpeg ? ".jpg" : ".png"))
        let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
            : rep.representation(using: .png, properties: [:])
        try? data?.write(to: url)
        print("screenshots: \(url.lastPathComponent)")
    }
}
#endif
