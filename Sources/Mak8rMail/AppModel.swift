#if os(macOS)
import AppKit
import ServiceManagement
#else
import UIKit
import UserNotifications
#endif
import MailCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case missingConfig
        case signedOut
        case signingIn
        case ready
    }

    private(set) var phase: Phase
    var signInError: String?
    @ObservationIgnored let notifier = Notifier()
    let drafts = DraftStore(directory: DraftStore.defaultDirectory)
    let settings = SettingsStore.live()
    /// Sent messages waiting out the undo-send delay.
    @ObservationIgnored private(set) var pendingSends: PendingSends!

    /// One session per signed-in account, in sidebar order.
    private(set) var sessions: [AccountSession] = []
    private(set) var accounts = AccountList()
    /// Accounts whose Google sign-in expired; each needs signing in again on its own.
    private(set) var expired: Set<String> = []

    var activeSession: AccountSession? { sessions.first { $0.email == accounts.active } }
    var store: MailStore? { activeSession?.store }
    var monitor: InboxMonitor? { activeSession?.monitor }
    var api: GmailAPI? { activeSession?.api }
    var me: String? { activeSession?.email }
    var totalUnread: Int { sessions.reduce(0) { $0 + $1.monitor.unreadCount } }

    /// Threads for which the user chose "Näytä kuvat".
    var remoteContentAllowed: Set<String> = []

    /// The sender whose trust decides remote images: the latest message not sent by me.
    func imageSender(of thread: MailThread) -> String? {
        thread.messages.last { !($0.from?.matches(me ?? "") ?? false) }?.from?.email
    }

    func imagesAllowed(in thread: MailThread) -> Bool {
        if remoteContentAllowed.contains(thread.id) { return true }
        switch settings.app.remoteImages {
        case .always: return true
        case .block: return false
        case .allowFromSenders:
            guard let me, let sender = imageSender(of: thread) else { return false }
            return settings.account(me).trustsImages(from: sender)
        }
    }

    func trustImages(from sender: String) {
        guard let me else { return }
        settings.updateAccount(me) { account in
            if !account.trustsImages(from: sender) { account.trustedImageSenders.append(sender.lowercased()) }
        }
    }
    /// Incremented to ask the sidebar search field to take focus.
    var searchFocusRequest = 0
    /// The in-window composer (bottom-right card / side peek).
    let composeDock = ComposeDock()

    var detailFocusRequest = 0
    #if os(macOS)
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Fork (seisemail): snooze, wake loop, inbox zero (Sources/Mak8rMail/Seise/).
    let seise = SeiseController()
    #endif

    @ObservationIgnored private let config: OAuthConfig?
    @ObservationIgnored private let accountsStore = AccountListStore(fileURL: AccountListStore.defaultURL)
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var backgroundStarted = false

    init() {
        config = OAuthConfig.fromBundle()
        phase = config == nil ? .missingConfig : .signedOut
        pendingSends = PendingSends(
            send: { [weak self] draft in try await self?.deliver(draft) },
            onFailure: { [weak self] draft, error in self?.reopenFailed(draft, error: error) }
        )
        #if os(macOS)
        seise.configure(settings: settings,
                        mainWindow: { [weak self] in self?.mainWindow },
                        isCurrent: { [weak self] session in self?.sessions.contains { $0 === session } ?? false },
                        isExpired: { [weak self] email in self?.expired.contains(email) ?? true },
                        onSignInExpired: { [weak self] email in self?.markExpired(email) })
        if let directory = ScreenshotDirector.outputDirectory {
            Task { await startScreenshots(into: directory) }
            return
        }
        #endif
        guard config != nil else { return }
        notifier.onOpenThread = { [weak self] id, account in
            guard let self else { return }
            self.openMainWindow?()
            guard let id else { return }
            Task { await self.openThread(id, account: account) }
        }
        Task { await bootstrap() }
    }

    // MARK: - Accounts

    private func bootstrap() async {
        guard let config else { return }
        let migrated = await AccountMigration.run(
            legacy: KeychainTokenStore(account: KeychainTokenStore.legacyAccountName),
            tokenStore: { KeychainTokenStore.forAccount($0) },
            accounts: accountsStore,
            legacyViewsURL: ViewsConfigStore.defaultURL,
            viewsURL: { ViewsConfigStore.url(for: $0) },
            fetchEmail: { store in
                let auth = GoogleAuth(config: config, store: store, transport: URLSessionTransport())
                return try await LiveGmailClient(auth: auth).profileEmail()
            }
        )
        guard let list = migrated else {
            signInError = "Ei yhteyttä. Yritetään uudelleen hetken kuluttua."
            try? await Task.sleep(for: .seconds(30))
            await bootstrap()
            return
        }
        signInError = nil
        accounts = list
        settings.preload(list.emails)
        for email in list.emails {
            #if os(macOS)
            seise.migrateViews(for: email)              // before MailStore.init reads the views file
            #endif
            let session = AccountSession.live(email: email, config: config, drafts: drafts)
            sessions.append(session)
            if await session.auth?.isSignedIn != true { expired.insert(email) }
        }
        if accounts.active == nil { accounts.active = accounts.emails.first }
        await startSessions()
    }

    #if os(macOS)
    /// `make screenshots`: one made-up account (DemoGmail) with its files under MAK8R_DATA_DIR; no Keychain,
    /// no Google, no notifications, no menu bar icon. Then ScreenshotDirector walks through the views.
    private func startScreenshots(into directory: URL) async {
        settings.app.menuBarIcon = false
        settings.app.inboxZeroDailyPhoto = false                     // the bundled photos, no network
        let email = DemoGmail.email
        accounts = AccountList(emails: [email], active: email)
        seise.migrateViews(for: email)
        let session = AccountSession(email: email, auth: nil, api: DemoGmail(),
                                     viewsStore: ViewsConfigStore(fileURL: ViewsConfigStore.url(for: email)), drafts: drafts)
        sessions = [session]
        updatePhase()
        await start(session)
        await ScreenshotDirector(app: self, directory: directory).run()
    }
    #endif

    /// Loads every signed-in account; the visible one first.
    private func startSessions() async {
        updatePhase()
        let ordered = sessions.sorted { a, _ in a.email == accounts.active }
        for session in ordered where !expired.contains(session.email) {
            await start(session)
        }
        guard phase == .ready || !sessions.isEmpty else { return }
        await startBackground()
    }

    private func start(_ session: AccountSession) async {
        applyReadingSettings(to: session.store)
        session.store.onUnreadChanged = { [weak self, weak session] id, unread in
            guard let self, let session else { return }
            session.monitor.noteChange(threadID: id, unread: unread, me: session.email) { [weak self] in
                self?.updateDockBadge()
            }
            self.updateDockBadge()
        }
        #if os(macOS)
        await seise.start(session)                      // fork (seisemail): daily counter, sorting labels, first load, launch wake pass
        #else
        await session.store.start()
        #endif
        _ = await session.monitor.check(me: session.email) // baseline: no notifications for mail already there
        if session.store.needsSignIn { markExpired(session.email) }
        updateDockBadge()
        // Launch argument for screenshots: `open "Mak8r Mail.app" --args -openFirstThread YES`
        let openFirst = settings.app.openFirstThread || UserDefaults.standard.bool(forKey: "openFirstThread")
        if session.email == accounts.active, openFirst,
           let first = session.store.threads.first {
            await session.store.select(threadID: first.id)
        }
        // `-openCompose YES` opens a new message, for screenshots of the composer.
        if session.email == accounts.active, UserDefaults.standard.bool(forKey: "openCompose") {
            openCompose(.new)
        }
        // `-filterFrom matti` adds filter chips, for screenshots of the filter bar.
        if session.email == accounts.active, let from = UserDefaults.standard.string(forKey: "filterFrom") {
            await session.store.setFilters([MailFilter(.from(from)), MailFilter(.attachment(nil))])
        }
        // `-checkThreads 3` pre-selects rows for screenshots of multi-select.
        if session.email == accounts.active {
            for thread in session.store.threads.prefix(UserDefaults.standard.integer(forKey: "checkThreads")) {
                session.store.toggleChecked(thread.id)
            }
        }
    }

    private func startBackground() async {
        guard !backgroundStarted else { return }
        backgroundStarted = true
        await notifier.requestPermission()
        #if os(macOS)
        enableLaunchAtLoginOnce()
        #endif
        lastRefresh = Date()
        startAutoRefresh()
    }

    private func updatePhase() {
        if phase == .signingIn { return }
        guard let active = accounts.active, !expired.contains(active) else {
            phase = .signedOut
            return
        }
        phase = .ready
    }

    private func saveAccounts() {
        try? accountsStore.save(accounts)
    }

    private func markExpired(_ email: String) {
        expired.insert(email)
        if email == accounts.active {
            signInError = "Kirjautuminen tilille \(email) on vanhentunut. Kirjaudu uudelleen."
        }
        updatePhase()
    }

    /// Switches the visible account.
    func switchAccount(_ email: String) {
        accounts.activate(email)
        saveAccounts()
        signInError = expired.contains(email) ? "Kirjautuminen tilille \(email) on vanhentunut. Kirjaudu uudelleen." : nil
        updatePhase()
    }

    /// Signs in with Google. Adds a new account, or renews the sign-in of an existing one.
    func signIn() {
        guard let config else { return }
        signInError = nil
        let previousPhase = phase
        phase = .signingIn
        signInTask = Task {
            let pending = MemoryTokenStore()
            let auth = GoogleAuth(config: config, store: pending, transport: URLSessionTransport())
            do {
                #if os(macOS)
                try await auth.signIn { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                #else
                try await auth.signIn(redirectURI: config.mobileRedirectURI) { url in
                    try await WebAuth.authenticate(url: url, callbackScheme: config.reversedClientIDScheme)
                }
                #endif
                let email = try await LiveGmailClient(auth: auth).profileEmail().lowercased()
                guard let tokens = await auth.currentTokens() else { throw AuthError.badResponse }
                KeychainTokenStore.forAccount(email).save(tokens)
                sessions.removeAll { $0.email == email }
                settings.preload([email])
                #if os(macOS)
                seise.migrateViews(for: email)
                #endif
                let session = AccountSession.live(email: email, config: config, drafts: drafts)
                sessions.append(session)
                sessions.sort { a, b in (accounts.emails.firstIndex(of: a.email) ?? .max) < (accounts.emails.firstIndex(of: b.email) ?? .max) }
                accounts.add(email)
                saveAccounts()
                expired.remove(email)
                phase = .ready
                await start(session)
                await startBackground()
            } catch is CancellationError {
                phase = previousPhase == .ready ? .ready : .signedOut
            } catch AuthError.denied {
                signInError = "Kirjautuminen peruttiin."
                phase = previousPhase == .ready ? .ready : .signedOut
            } catch {
                signInError = "Kirjautuminen epäonnistui. Yritä uudelleen."
                phase = previousPhase == .ready ? .ready : .signedOut
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Signs the account out and forgets it.
    func removeAccount(_ email: String) async {
        guard let session = sessions.first(where: { $0.email == email }) else { return }
        await session.auth?.signOut()
        sessions.removeAll { $0.email == email }
        #if os(macOS)
        seise.accountRemoved(email)
        #endif
        expired.remove(email)
        accounts.remove(email)
        saveAccounts()
        updateDockBadge()
        signInError = nil
        updatePhase()
    }

    func signOut() async {
        if let active = accounts.active { await removeAccount(active) }
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refreshNow()
            }
        }
        #if os(macOS)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        #else
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        #endif
        activationObserver = NotificationCenter.default.addObserver(
            forName: didBecomeActive, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastRefresh) > 10 else { return }
                await self.refreshNow()
            }
        }
    }

    /// Refreshes the visible list and checks every account for new mail.
    func refreshNow() async {
        lastRefresh = Date()
        if let store, phase == .ready { await store.refresh() }
        for session in sessions where !expired.contains(session.email) {
            let events = await session.monitor.check(me: session.email)
            if settings.account(session.email).notificationsEnabled {
                notifier.post(
                    events,
                    account: sessions.count > 1 ? session.email : nil,
                    sound: settings.app.notificationSound ? settings.app.notificationSoundName : nil
                )
            }
            if session.store.needsSignIn { markExpired(session.email) }
            #if os(macOS)
            await seise.refreshSummary(email: session.email)    // fork (seisemail): snoozed counts, 1–3 units
            #endif
        }
        updateDockBadge()
    }

    /// Called when the visible store reports an expired sign-in.
    func handleExpiredActive() {
        if let active = accounts.active { markExpired(active) }
    }

    // MARK: - Background: badge, notifications, login item

    /// Set by the main window so notifications and the menu bar can bring it back after it was closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    func openThread(_ id: String, account: String? = nil) async {
        if let account, account != accounts.active { switchAccount(account) }
        #if os(macOS)
        await store?.openPreferringCurrentView(threadID: id)   // fork (seisemail): stays in Käsiteltävät when listed
        #else
        await store?.openInInbox(threadID: id)
        #endif
    }

    private func updateDockBadge() {
        let count = settings.app.dockBadge ? totalUnread : 0
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }

    // MARK: - Settings

    /// Pushes changed app settings to every account's store and the Dock.
    func applySettings() {
        for session in sessions { applyReadingSettings(to: session.store) }
        updateDockBadge()
    }

    private func applyReadingSettings(to store: MailStore) {
        store.markReadPolicy = settings.app.markRead
        store.afterArchive = settings.app.afterArchive
    }

    var menuBarIconShown: Bool {
        get { settings.app.menuBarIcon }
        set {
            // MenuBarExtra writes this binding on every scene update; writing an unchanged value
            // would invalidate `settings.app`, re-run the scene body and loop forever.
            guard settings.app.menuBarIcon != newValue else { return }
            settings.app.menuBarIcon = newValue
        }
    }

    #if os(macOS)
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                store?.toast = "Kirjautumiskohteen muutos epäonnistui"
            }
        }
    }

    /// Launch at login defaults to on, set once; afterwards the Settings toggle decides.
    private func enableLaunchAtLoginOnce() {
        let key = "launchAtLoginConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        launchAtLogin = true
    }
    #endif

    // MARK: - Commands

    func perform(_ command: MailCommand) async {
        guard let store else { return }
        switch command {
        case .next: await store.selectNext()
        case .previous: await store.selectPrevious()
        case .open:
            if let id = store.selectedThreadID {
                if store.isPeekOpen { detailFocusRequest += 1 } else { await store.select(threadID: id) }
            } else {
                await store.selectNext()
            }
        case .back:
            if !store.checkedIDs.isEmpty { store.clearChecked() } else if store.isPeekOpen { store.closePeek() }
        case .archive: await store.archive()
        case .star: await store.toggleStar()
        case .trash: await store.trash()
        case .markUnread: await store.markUnread()
        case .reply: openCompose(.reply)
        case .replyAll: openCompose(.replyAll)
        case .forward: openCompose(.forward)
        case .compose: openCompose(.new)
        case .search: searchFocusRequest += 1
        case .undo: await store.undo()
        case .toggleCheck:
            if let id = store.selectedThreadID { store.toggleChecked(id) }
        case .checkAll: store.checkAll()
        case .markRead: await store.markRead()
        case .snooze:                                   // fork (seisemail)
            #if os(macOS)
            seise.openMenu(session: activeSession)
            #else
            break
            #endif
        }
    }

    /// ⌥1…9: the n-th view in the sidebar.
    func switchView(_ n: Int) async {
        guard let store, n >= 1, n <= store.views.count else { return }
        await store.selectView(store.views[n - 1].id)
    }

    func openCompose(_ kind: ComposeKind) {
        guard let draft = draft(for: kind) else { return }
        presentCompose(draft)
    }

    // MARK: - Compose

    /// Opens `draft` in the composer card. `restored` drafts came from disk and stay saved even if untouched.
    func presentCompose(_ draft: Draft, restored: Bool = false) {
        let session = ComposeSession(draft: draft, store: drafts, keepOnClose: restored) { [weak self] draft in
            try await self?.send(draft)
        }
        composeDock.present(session)
        openMainWindow?()
    }

    /// Checks the recipients, then sends after the undo-send delay (at once when it is off).
    /// The sending account is fixed now, so switching accounts during the delay changes nothing.
    func send(_ draft: Draft) async throws {
        try ComposeController.validate(draft)
        var pinned = draft
        if pinned.account == nil {
            pinned.account = accounts.active
            try? drafts.save(pinned)
        }
        try await pendingSends.enqueue(pinned, delaySeconds: settings.app.undoSendSeconds)
    }

    /// Errors for drafts whose delayed send failed; the reopened composer shows them.
    var sendErrors: [UUID: String] = [:]

    /// A delayed send failed: bring the draft back in the composer with the error.
    func reopenFailed(_ draft: Draft, error: Error) {
        sendErrors[draft.id] = Self.sendErrorMessage(error)
        presentCompose(draft, restored: true)
    }

    static func sendErrorMessage(_ error: Error) -> String {
        switch error {
        case ComposeError.noRecipients: "Lisää vähintään yksi vastaanottaja."
        case ComposeError.invalidAddress(let address): "Virheellinen osoite: \(address)"
        case ComposeError.tooLarge: "Viesti on liian suuri (yli 35 Mt)."
        case GmailError.offline: "Ei yhteyttä. Viesti on tallessa luonnoksena."
        case GmailError.rateLimited: "Gmail rajoittaa pyyntöjä. Viesti on tallessa luonnoksena."
        default: "Lähetys epäonnistui. Viesti on tallessa luonnoksena."
        }
    }

    /// Takes a message back during the undo-send delay and reopens it for editing.
    func undoSend(_ id: UUID) {
        guard let draft = pendingSends.cancel(id: id) else { return }
        // Still saved on disk, so it reopens as a restored draft.
        presentCompose(draft, restored: true)
    }

    private func session(for draft: Draft) -> AccountSession? {
        let email = draft.account ?? accounts.active
        return sessions.first { $0.email == email }
    }

    /// Sends from the draft's account (the active one for drafts saved before multiple accounts).
    private func deliver(_ draft: Draft) async throws {
        guard let session = session(for: draft) else { throw GmailError.offline }
        try await session.composer.send(draft, from: session.email)
        session.store.toast = "Viesti lähetetty"
        if draft.threadID != nil {
            Task { await session.store.refresh() }
        }
    }

    /// Drafts left over from an earlier session that the composer is not showing.
    var unsentDrafts: [Draft] {
        let pending = Set(pendingSends.items.map(\.id))
        return drafts.all().filter { $0.id != composeDock.current?.draft.id && !pending.contains($0.id) }
    }

    /// Opens the newest leftover draft; the rest stay saved and are offered again next launch.
    func restoreDrafts() {
        if let newest = unsentDrafts.first { presentCompose(newest, restored: true) }
    }

    func discardUnsentDrafts() {
        for draft in unsentDrafts { drafts.delete(id: draft.id) }
    }

    func draft(for kind: ComposeKind) -> Draft? {
        guard let store, let me else { return nil }
        let account = settings.account(me)
        var draft: Draft
        switch kind {
        case .new:
            draft = ComposeFactory.new(signature: account.signature(for: .new))
        case .reply, .replyAll, .forward:
            guard let thread = store.openThread, let message = thread.messages.last else { return nil }
            let signature = account.signature(for: .reply)
            switch kind {
            case .reply: draft = ComposeFactory.reply(to: message, in: thread, me: me, all: false, signature: signature)
            case .replyAll: draft = ComposeFactory.reply(to: message, in: thread, me: me, all: true, signature: signature)
            default: draft = ComposeFactory.forward(message, in: thread, signature: signature)
            }
        }
        draft.account = me
        return draft
    }
}

enum ComposeKind {
    case new, reply, replyAll, forward
}
